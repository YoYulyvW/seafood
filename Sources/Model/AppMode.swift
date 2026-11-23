import Foundation

/// 使用模式：本地版只写本机 SQLite；远程版额外把数据同步到团队共用的 MySQL。
enum AppMode: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "本地版"
        case .remote: return "远程版"
        }
    }

    var summary: String {
        switch self {
        case .local: return "数据只存在这台手机上，不联网、不同步。"
        case .remote: return "几个人共用同一台 MySQL 的库存，写入后自动同步。"
        }
    }

    /// 当前选择的模式；返回 nil 表示还没选过（首次启动）。
    static var selected: AppMode? {
        AppMode(rawValue: SQLiteStore.shared.setting("app_mode"))
    }

    static func save(_ mode: AppMode) {
        SQLiteStore.shared.setSetting("app_mode", mode.rawValue)
    }
}
