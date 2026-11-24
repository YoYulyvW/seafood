import SwiftUI
import UniformTypeIdentifiers

/// TLS 三档，值直接对应 MySQLConfig.tls 的字符串。
private struct TLSOption: Identifiable {
    let id: String
    let label: String
}

/// 设置页：操作员、远程 MySQL 同步、检查更新、数据维护、关于。
@MainActor
struct SettingsView: View {
    @EnvironmentObject private var sync: SyncEngine
    @EnvironmentObject private var updater: UpdateChecker

    @State private var operatorName = ""

    @State private var syncOn = false
    @State private var host = ""
    @State private var port = "3306"
    @State private var user = ""
    @State private var password = ""
    @State private var database = ""
    @State private var tls = "preferred"
    @State private var dsnText = ""
    @State private var syncMessage: String? = nil
    @State private var syncError: String? = nil
    @State private var syncWorking = false

    @State private var confirmClear = false
    @State private var confirmPull = false
    @State private var dataMessage: String? = nil
    @AppStorage("lowstock_notify") private var lowStockNotify = true
    @AppStorage("show_profit") private var showProfit = true
    @AppStorage("alert_style") private var alertStyle = "bubble"
    @State private var syncExpanded = false
    @State private var updateError: String? = nil
    @State private var updateURLText = ""
    @State private var confirmDemo = false
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var localIPA: URL? = nil

    /// 使用模式：与 RootView 共用同一个 UserDefaults 键。
    @AppStorage("app_mode") private var appMode = ""
    @State private var showModeSetup = false
    @State private var modeMessage: String? = nil

    private static let tlsOptions: [TLSOption] = [
        TLSOption(id: "preferred", label: "首选"),
        TLSOption(id: "required", label: "强制"),
        TLSOption(id: "disabled", label: "关闭")
    ]

    var body: some View {
        NavigationStack {
            List {
                modeSection
                operatorSection
                syncSection
                alertSection
                displaySection
                dataSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importBackup(from: url)
                } else if case .failure(let error) = result {
                    dataMessage = "选择文件失败：" + error.localizedDescription
                }
            }
            .sheet(isPresented: Binding(get: { exportURL != nil },
                                        set: { if !$0 { exportURL = nil } })) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
            .alert(SQLiteStore.shared.hasDemoData() ? "清空演示数据？" : "写入演示数据？",
                   isPresented: $confirmDemo) {
                Button("取消", role: .cancel) {}
                Button(SQLiteStore.shared.hasDemoData() ? "清空演示数据" : "写入演示数据",
                       role: SQLiteStore.shared.hasDemoData() ? .destructive : nil) {
                    if SQLiteStore.shared.hasDemoData() {
                        SQLiteStore.shared.clearDemoData()
                        dataMessage = "演示数据已清空，你手工录入的数据没动"
                    } else {
                        SQLiteStore.shared.seedDemoNow()
                        dataMessage = "已写入演示数据，再双击可清掉"
                    }
                    Haptic.success()
                }
            } message: {
                Text(SQLiteStore.shared.hasDemoData()
                     ? "只删除演示写入的品类与流水，手动录入的数据会保留。"
                     : "会写入 8 个品类与一批示例流水，只用于试功能。")
            }
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadFields() }
            .alert("清空本地数据？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { clearAllData() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("品类、批次、流水会全部删除，且不可恢复。远程库不受影响。")
            }
            .alert("用远程数据覆盖本地？", isPresented: $confirmPull) {
                Button("覆盖", role: .destructive) { pullReplace() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本地品类、批次、流水会被远程整库替换。如果本地还有没推上去的记录，先点“立即同步”。")
            }
            .fullScreenCover(isPresented: $showModeSetup) {
                ModeSetupView(showsClose: true) {
                    showModeSetup = false
                }
            }
            .onChange(of: appMode) { value in
                if value == "remote" {
                    modeMessage = "已切到远程版，正在后台同步"
                } else if value == "local" {
                    modeMessage = "已切到本地版，自动同步已停止，本地数据保留"
                }
                loadFields()
            }
        }
    }

    // MARK: - 使用模式

    private var modeLabel: String {
        switch appMode {
        case "local": return "本地版"
        case "remote": return "远程版"
        default: return "未设置"
        }
    }

    @ViewBuilder
    private var modeSection: some View {
        Section {
            KVLine(title: "当前模式", value: modeLabel, valueColor: Theme.ink)
                .listRowBackground(Theme.surface)

            Button {
                switchToLocal()
            } label: {
                HStack {
                    Text("切换到本地版")
                    Spacer()
                    if appMode == "local" {
                        Image(systemName: "checkmark")
                            .font(.footnote)
                            .foregroundStyle(Theme.jade)
                    }
                }
            }
            .disabled(appMode == "local")
            .listRowBackground(Theme.surface)

            Button {
                switchToRemote()
            } label: {
                HStack {
                    Text("切换到远程版")
                    Spacer()
                    if appMode == "remote" {
                        Image(systemName: "checkmark")
                            .font(.footnote)
                            .foregroundStyle(Theme.jade)
                    }
                }
            }
            .disabled(appMode == "remote")
            .listRowBackground(Theme.surface)

            if let modeMessage {
                Text(modeMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("使用模式")
        } footer: {
            Text("本地版只写本机 SQLite；远程版多人共用一台 MySQL，写入后自动同步。切模式不会删数据。")
        }
    }

    private var syncSummary: String {
        if let cfg = sync.config {
            return cfg.host + ":" + String(cfg.port) + "/" + cfg.database
        }
        return "未配置"
    }

    // MARK: - 操作员

    @ViewBuilder
    private var operatorSection: some View {
        Section {
            HStack(spacing: Theme.s2) {
                TextField("例如：小码酱", text: $operatorName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .listRowBackground(Theme.surface)
                .onChange(of: operatorName) { value in
                    SQLiteStore.shared.setSetting("operator", value)
                }
                Button("随机") {
                    operatorName = OperatorNames.random()
                }
                .font(.footnote)
                .foregroundStyle(Theme.signal)
            }
            NavigationLink {
                AuditLogView()
            } label: {
                Text("审计日志")
            }
            .listRowBackground(Theme.surface)
        } header: {
            Text("操作员")
        } footer: {
            Text("会写进每一条流水的操作人字段。")
        }
    }

    // MARK: - 远程同步

    @ViewBuilder
    private var syncSection: some View {
        Section {
            DisclosureGroup(isExpanded: $syncExpanded) {
            Toggle("启用远程同步", isOn: $syncOn)
                .tint(Theme.jade)
                .listRowBackground(Theme.surface)
                .onChange(of: syncOn) { value in
                    saveConfig(enabled: value)
                }

            if syncOn {
                HStack {
                    Text("主机")
                    Spacer(minLength: Theme.s2)
                    TextField("127.0.0.1", text: $host)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Theme.surface)

                HStack {
                    Text("端口")
                    Spacer(minLength: Theme.s2)
                    TextField("3306", text: $port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                .listRowBackground(Theme.surface)

                HStack {
                    Text("用户")
                    Spacer(minLength: Theme.s2)
                    TextField("root", text: $user)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Theme.surface)

                HStack {
                    Text("密码")
                    Spacer(minLength: Theme.s2)
                    SecureField("", text: $password)
                        .multilineTextAlignment(.trailing)
                }
                .listRowBackground(Theme.surface)

                HStack {
                    Text("库名")
                    Spacer(minLength: Theme.s2)
                    TextField("seafood", text: $database)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .listRowBackground(Theme.surface)

                VStack(alignment: .leading, spacing: Theme.s2) {
                    Text("TLS")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                    InkSegmented(options: Self.tlsOptions.map { ($0.id, $0.label) }, selection: $tls)
                }
                .listRowBackground(Theme.surface)

                VStack(alignment: .leading, spacing: Theme.s2) {
                    TextField("mysql://user:pass@host:3306/db", text: $dsnText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.number(12, weight: .regular))
                    Button("从 DSN 填充") { fillFromDSN() }
                        .font(.footnote)
                        .foregroundStyle(Theme.signal)
                }
                .listRowBackground(Theme.surface)
            }

            syncStateRow
                .listRowBackground(Theme.surface)

            if let last = sync.lastSync {
                KVLine(title: "上次同步", value: Fmt.dayTime.string(from: last))
                    .listRowBackground(Theme.surface)
            } else {
                KVLine(title: "上次同步", value: "从未", valueColor: Theme.ink3)
                    .listRowBackground(Theme.surface)
            }

            KVLine(title: "当前 DSN", value: maskedDSN, valueColor: Theme.ink3)
                .listRowBackground(Theme.surface)

            if appMode == "local" {
                Text("本地版也会把数据同步到这台 MySQL，当作备份用。")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .listRowBackground(Theme.surface)
            }

            if let warning = sync.tlsWarning {
                HStack(alignment: .top, spacing: Theme.s2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                    Text(warning)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.s2)
                    Button("知道了") { sync.tlsWarning = nil }
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(Theme.signal)
                .listRowBackground(Theme.surface)
            }

            if let syncMessage {
                Text(syncMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.jade)
                    .listRowBackground(Theme.surface)
            }
            if let syncError {
                ErrorLine(text: syncError)
                    .listRowBackground(Theme.surface)
            }

            Button {
                testConnection()
            } label: {
                HStack {
                    Text(syncWorking ? "请稍候…" : "测试连接")
                    Spacer()
                    Image(systemName: "bolt.horizontal")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .disabled(syncWorking)
            .listRowBackground(Theme.surface)

            Button {
                runSync()
            } label: {
                HStack {
                    Text("立即同步")
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .disabled(syncWorking)
            .listRowBackground(Theme.surface)

            Button(role: .destructive) {
                confirmPull = true
            } label: {
                HStack {
                    Text("从远程覆盖本地")
                    Spacer()
                    Image(systemName: "arrow.down.doc")
                        .font(.footnote)
                }
            }
            .disabled(syncWorking)
            .listRowBackground(Theme.surface)
            } label: {
                HStack {
                    Text("MySQL 备份 / 同步")
                    Spacer(minLength: Theme.s2)
                    Text(syncSummary)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
        } header: {
            Text("同步")
        } footer: {
            Text("写入本地后 2 秒内自动推送。远程覆盖会用服务端整库替换本地。密码只存 Keychain，数据库里不留明文。")
        }
    }

    @ViewBuilder
    private var syncStateRow: some View {
        switch sync.state {
        case .idle:
            KVLine(title: "同步状态", value: "未同步", valueColor: Theme.ink3)
        case .syncing:
            HStack(spacing: Theme.s2) {
                Text("同步状态")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: Theme.s2)
                ProgressView()
                    .scaleEffect(0.8)
                Text("同步中…")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink2)
            }
        case .success(let date):
            KVLine(title: "同步状态", value: "成功 · " + Fmt.dayTime.string(from: date), valueColor: Theme.jade)
        case .failed(let message):
            ErrorLine(text: message)
        }
    }

    // MARK: - 库存预警

    @ViewBuilder
    private var alertSection: some View {
        Section {
            NavigationLink {
                CategoryAlertsView()
            } label: {
                HStack {
                    Text("品类与预警")
                    Spacer()
                    Text("预警线 / 存储方式")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .listRowBackground(Theme.surface)

            InkSegmented(options: [("bubble", "气泡"), ("bar", "顶部横条")], selection: $alertStyle)
                .padding(.vertical, 4)
                .listRowBackground(Theme.surface)

            Toggle("低库存通知", isOn: $lowStockNotify)
                .tint(Theme.jade)
                .listRowBackground(Theme.surface)
                .onChange(of: lowStockNotify) { enabled in
                    guard enabled else { return }
                    Task { _ = await LowStockNotifier.shared.requestAuthorization() }
                }
        } header: {
            Text("库存")
        } footer: {
            Text("低于预警线的品类在库存页标红；同一品类每天最多提醒一次。")
        }
    }

    // MARK: - 数据

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Text("清空本地数据")
            }
            .listRowBackground(Theme.surface)

            Button {
                exportBackup()
            } label: {
                Text("导出备份文件")
            }
            .listRowBackground(Theme.surface)

            Button {
                showImporter = true
            } label: {
                Text("从备份文件导入")
            }
            .listRowBackground(Theme.surface)

            if let dataMessage {
                Text(dataMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                    .listRowBackground(Theme.surface)
            }
        } header: {
            Text("数据")
        } footer: {
            Text("清空后需要重新录入，或从远程同步拉回。")
        }
    }

    // MARK: - 关于（含更新）

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            Button {
                checkUpdate()
            } label: {
                HStack(spacing: Theme.s2) {
                    Text("版本")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(updater.currentVersion + " (" + String(updater.currentBuild) + ")")
                        .foregroundStyle(Theme.ink2)
                        .monospacedDigit()
                    if updater.checking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(updater.checking || updater.downloading)
            .listRowBackground(Theme.surface)

            if let latest = updater.latest {
                VStack(alignment: .leading, spacing: Theme.s2) {
                    KVLine(title: "线上版本", value: latest.version + " (" + String(latest.build) + ")")
                    if !latest.notes.isEmpty {
                        Text(latest.notes)
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    KVLine(title: "安装包", value: ByteSize.text(latest.size))
                    if updater.hasUpdate {
                        if updater.downloading {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(Theme.signal)
                                .padding(.vertical, 4)
                            Text("下载中…")
                                .font(.caption)
                                .foregroundStyle(Theme.ink3)
                        } else if let localIPA {
                            Button {
                                installUpdate(latest)
                            } label: {
                                Text("用 TrollStore 安装")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.signal)
                            }
                            Text(localIPA.lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                        } else {
                            Button {
                                downloadUpdate(latest)
                            } label: {
                                Text("下载更新")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.signal)
                            }
                        }
                    } else {
                        Text("已是最新版本")
                            .font(.footnote)
                            .foregroundStyle(Theme.jade)
                    }
                }
                .listRowBackground(Theme.surface)
            }

            if let updateError {
                ErrorLine(text: updateError)
                    .listRowBackground(Theme.surface)
            }

            HStack(spacing: Theme.s2) {
                Text("更新地址")
                Spacer(minLength: Theme.s2)
                TextField("留空则用构建注入的值", text: $updateURLText)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.number(11, weight: .regular))
                    .onChange(of: updateURLText) { value in
                        SQLiteStore.shared.setSetting("update_url",
                                                      value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
            }
            .listRowBackground(Theme.surface)

            KVLine(title: "数据存储",
                   value: SQLiteStore.shared.hasDemoData() ? "本地 SQLite · 含演示数据" : "本地 SQLite",
                   valueColor: Theme.ink3)
                .listRowBackground(Theme.surface)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { confirmDemo = true }
        } header: {
            Text("关于")
        } footer: {
            Text("点版本号检查更新；安装包校验大小与 sha256 后交给 TrollStore 安装。")
        }
    }

    // MARK: - 模式动作

    private var maskedDSN: String {
        guard let config = sync.config else { return "未配置" }
        let auth = config.password.isEmpty ? config.user : config.user + ":••••"
        return "mysql://" + auth + "@" + config.host + ":" + String(config.port) + "/" + config.database
    }

    private func switchToLocal() {
        sync.setMode(.local)
        Haptic.tap()
    }

    private func switchToRemote() {
        if sync.isConfigured {
            sync.setMode(.remote)
            Haptic.success()
        } else {
            showModeSetup = true
            Haptic.tap()
        }
    }

    // MARK: - 同步动作

    private func loadFields() {
        updateURLText = SQLiteStore.shared.setting("update_url")
        operatorName = SQLiteStore.shared.setting("operator")
        let config = sync.config
        syncOn = config != nil
        if let config {
            host = config.host
            port = String(config.port)
            user = config.user
            password = config.password
            database = config.database
            tls = config.tls
            // dsnText 留空：不把带密码的 DSN 明文塞回输入框，当前 DSN 单独打码展示
            dsnText = ""
        } else {
            host = "127.0.0.1"
            port = "3306"
            user = "root"
            database = "seafood"
            tls = "preferred"
        }
    }

    private func buildConfig() -> MySQLConfig? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return nil }
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return MySQLConfig(
            host: trimmedHost,
            port: Int(trimmedPort) ?? 3306,
            user: user.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            database: database.trimmingCharacters(in: .whitespacesAndNewlines),
            tls: tls
        )
    }

    private func saveConfig(enabled: Bool) {
        guard enabled else {
            sync.saveConfig(nil)
            syncMessage = nil
            syncError = nil
            return
        }
        guard let config = buildConfig() else {
            syncError = "请填写主机地址"
            return
        }
        sync.saveConfig(config)
        syncError = nil
        syncMessage = "连接配置已保存"
    }

    private func fillFromDSN() {
        syncError = nil
        syncMessage = nil
        let raw = dsnText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let config = MySQLConfig(dsn: raw) else {
            syncError = "DSN 格式不正确，示例 mysql://root:pass@127.0.0.1:3306/seafood"
            return
        }
        host = config.host
        port = String(config.port)
        user = config.user
        password = config.password
        database = config.database
        tls = config.tls
        syncOn = true
        sync.saveConfig(config)
        syncMessage = "已从 DSN 解析并保存"
    }

    private func testConnection() {
        syncError = nil
        syncMessage = nil
        guard let config = buildConfig() else {
            syncError = "请填写主机地址"
            return
        }
        sync.saveConfig(config)
        syncOn = true
        syncWorking = true
        Task {
            do {
                let info = try await sync.testConnection()
                syncMessage = "连接成功：" + info
                Haptic.success()
            } catch {
                syncError = uiErrorText(error)
                Haptic.error()
            }
            syncWorking = false
        }
    }

    private func runSync() {
        syncError = nil
        syncMessage = nil
        guard sync.isConfigured else {
            syncMessage = "还没配置 MySQL：填好下面连接信息后才能同步"
            return
        }
        guard let config = buildConfig() else {
            syncError = "请先填写连接信息"
            return
        }
        sync.saveConfig(config)
        syncWorking = true
        Task {
            do {
                let report = try await sync.syncNow()
                syncMessage = "同步完成：推送 " + String(report.pushed) + " 条，拉取 " + String(report.pulled) + " 条"
                Haptic.success()
            } catch {
                syncError = uiErrorText(error)
                Haptic.error()
            }
            syncWorking = false
        }
    }

    private func pullReplace() {
        syncError = nil
        syncMessage = nil
        guard sync.isConfigured else {
            syncMessage = "还没配置 MySQL：填好下面连接信息后才能同步"
            return
        }
        syncWorking = true
        Task {
            do {
                let report = try await sync.pullReplace()
                syncMessage = "已用远程覆盖本地：拉取 " + String(report.pulled) + " 条"
                Haptic.success()
            } catch {
                syncError = uiErrorText(error)
                Haptic.error()
            }
            syncWorking = false
        }
    }

    // MARK: - 更新动作

    private func checkUpdate() {
        updateError = nil
        Task {
            await updater.check()
            if let text = updater.errorText {
                updateError = text
            }
        }
    }

    private func downloadUpdate(_ info: UpdateInfo) {
        updateError = nil
        Task {
            do {
                localIPA = try await updater.download(info)
                Haptic.success()
            } catch {
                updateError = uiErrorText(error)
                Haptic.error()
            }
        }
    }

    private func installUpdate(_ info: UpdateInfo) {
        updateError = nil
        Task {
            do {
                try await updater.installWithTrollStore(info, localFile: localIPA)
            } catch {
                updateError = uiErrorText(error)
                Haptic.error()
            }
        }
    }

    // MARK: - 显示

    @ViewBuilder
    private var displaySection: some View {
        Section {
            Toggle("流水页显示毛利", isOn: $showProfit)
                .tint(Theme.jade)
                .listRowBackground(Theme.surface)
        } header: {
            Text("显示")
        } footer: {
            Text("毛利 = 出库金额 − 该笔扣到的批次进价，按先进先出计算。")
        }
    }

    // MARK: - 数据动作

    private func clearAllData() {
        SQLiteStore.shared.resetAll()
        localIPA = nil
        dataMessage = "本地数据已清空"
        Haptic.warning()
    }

    private func exportBackup() {
        do {
            let data = try SQLiteStore.shared.exportBackup()
            let name = "seafood-backup-" + Fmt.dayString(Date()) + ".json"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            exportURL = url
            dataMessage = "已生成备份：" + name
            Haptic.success()
        } catch {
            dataMessage = "导出失败：" + error.localizedDescription
            Haptic.error()
        }
    }

    private func importBackup(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try SQLiteStore.shared.importBackup(data)
            dataMessage = "备份已导入，本地数据已替换"
            Haptic.success()
        } catch {
            dataMessage = "导入失败：" + error.localizedDescription
            Haptic.error()
        }
    }
}
