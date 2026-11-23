import SwiftUI
import UIKit

/// 两张大卡二选一。
private enum ModeSelection: String {
    case local
    case remote
}

/// 首次启动 / 切换模式的全屏选择：本地版 或 远程版。
@MainActor
struct ModeSetupView: View {
    /// 从设置页弹出时显示「取消」，首次启动时不显示。
    var showsClose: Bool
    var onClose: () -> Void

    @EnvironmentObject private var sync: SyncEngine

    @State private var selection: ModeSelection = .local
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var user = "root"
    @State private var password = ""
    @State private var database = "seafood"
    @State private var dsnText = ""
    @State private var testing = false
    @State private var testResult: String? = nil
    @State private var errorText: String? = nil

    init(showsClose: Bool = false, onClose: @escaping () -> Void = {}) {
        self.showsClose = showsClose
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PaperBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s4) {
                        if showsClose { closeBar }
                        header
                        localCard
                        remoteCard
                        footer
                    }
                    .padding(Theme.s4)
                    .padding(.bottom, Theme.s6)
                }
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成") { hideKeyboard() }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { prefill() }
    }

    // MARK: - 头部

    private var closeBar: some View {
        HStack {
            Spacer()
            Button("取消") { onClose() }
                .font(.subheadline)
                .foregroundStyle(Theme.ink3)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("过 磅 单")
                .font(Theme.label())
                .tracking(3)
                .foregroundStyle(Theme.ink3)
            Text("选择使用方式")
                .font(Theme.title(28))
                .foregroundStyle(Theme.ink)
            Text("本地版只存本机；远程版多人共用一台 MySQL，写入后自动同步。")
                .font(.footnote)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.s2)
    }

    // MARK: - 本地版

    private var localCard: some View {
        ModeCard(selected: selection == .local) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(alignment: .top, spacing: Theme.s3) {
                    Image(systemName: "iphone")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地版")
                            .font(Theme.title(20))
                            .foregroundStyle(Theme.ink)
                        Text("数据只存在本机 SQLite，不联网、不同步。适合一个人一台机。")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.s2)
                    if selection == .local {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.jade)
                    }
                }

                Button {
                    applyLocal()
                } label: {
                    Text("用本地版")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = .local }
        }
    }

    // MARK: - 远程版

    private var remoteCard: some View {
        ModeCard(selected: selection == .remote) {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(alignment: .top, spacing: Theme.s3) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("远程版")
                            .font(Theme.title(20))
                            .foregroundStyle(Theme.ink)
                        Text("多人共用一台 MySQL 的库存，写入 2 秒内自动推送。")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.s2)
                    if selection == .remote {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(Theme.jade)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.s3) {
                    HStack(alignment: .top, spacing: Theme.s3) {
                        LabeledField("主机") {
                            TextField("127.0.0.1", text: $host)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .inkField()
                        }
                        LabeledField("端口") {
                            TextField("3306", text: $port)
                                .keyboardType(.numberPad)
                                .inkField()
                        }
                        .frame(width: 96)
                    }

                    LabeledField("用户") {
                        TextField("root", text: $user)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .inkField()
                    }

                    LabeledField("密码") {
                        SecureField("数据库密码", text: $password)
                            .inkField()
                    }

                    LabeledField("库名") {
                        TextField("seafood", text: $database)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .inkField()
                    }

                    LabeledField("粘贴 DSN", hint: "粘 mysql://user:pass@host:3306/db 会自动拆到上面各栏") {
                        TextField("mysql://…", text: $dsnText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.number(12, weight: .regular))
                            .inkField()
                            .onChange(of: dsnText) { value in
                                splitDSN(value)
                            }
                    }

                    HStack(spacing: Theme.s3) {
                        Button {
                            testConnection()
                        } label: {
                            Label(testing ? "测试中…" : "测试连接", systemImage: "bolt.horizontal")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(testing)

                        Button {
                            applyRemote()
                        } label: {
                            Text("用远程版")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(testing)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = .remote }

                if let testResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                            .font(.caption)
                        Text("连接成功：" + testResult)
                            .font(.footnote)
                    }
                    .foregroundStyle(Theme.jade)
                }

                if let warning = sync.tlsWarning {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                        Text(warning)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.signal)
                }

                if let errorText {
                    ErrorLine(text: errorText)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = .remote }
        }
    }

    private var footer: some View {
        Text("随时可以在「设置 → 使用模式」里切换；切到本地版不会删除已有数据。")
            .font(.caption)
            .foregroundStyle(Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 动作

    private func prefill() {
        selection = sync.mode == .remote ? .remote : .local
        guard let config = sync.config else { return }
        host = config.host
        port = String(config.port)
        user = config.user
        password = config.password
        database = config.database
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
            tls: "preferred"
        )
    }

    private func splitDSN(_ raw: String) {
        guard let config = MySQLConfig(dsn: raw) else { return }
        host = config.host
        port = String(config.port)
        user = config.user
        password = config.password
        database = config.database
        selection = .remote
        errorText = nil
    }

    private func testConnection() {
        errorText = nil
        testResult = nil
        guard let config = buildConfig() else {
            errorText = "请先填写主机地址"
            Haptic.warning()
            return
        }
        sync.saveConfig(config)
        testing = true
        Task {
            do {
                let version = try await sync.testConnection()
                testResult = version
                Haptic.success()
            } catch {
                errorText = uiErrorText(error)
                Haptic.error()
            }
            testing = false
        }
    }

    private func applyLocal() {
        selection = .local
        SQLiteStore.shared.seedIfNeeded()   // 只给本地版灌演示数据；远程版空库开始
        sync.setMode(.local)
        Haptic.success()
        onClose()
    }

    private func applyRemote() {
        errorText = nil
        guard let config = buildConfig() else {
            errorText = "请先填写主机地址"
            Haptic.warning()
            return
        }
        sync.saveConfig(config)
        sync.setMode(.remote)
        selection = .remote
        Haptic.success()
        onClose()
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - 可选中的大卡

/// 选中态 2px 墨线描边，未选中 1px 浅线。
private struct ModeCard<Content: View>: View {
    let selected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.s4)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(selected ? Theme.ink : Theme.ruleSoft, lineWidth: selected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: selected)
    }
}
