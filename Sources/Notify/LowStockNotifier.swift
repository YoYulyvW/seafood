import Foundation
import UserNotifications

/// 低库存通知：同一品类同一天只提醒一次，避免每次进出库都轰炸。
@MainActor
final class LowStockNotifier {
    static let shared = LowStockNotifier()

    private let center = UNUserNotificationCenter.current()
    private let keyPrefix = "lowstock.notified."

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// 传 rows 可复用调用方已经查好的库存；nil 时自己查。
    func check(rows: [StockRow]? = nil) async {
        let low = (rows ?? SQLiteStore.shared.stock()).filter { $0.isLow }
        guard !low.isEmpty else { return }
        // 静默只针对“被关掉的那一条”；库存再往下掉就是新告警，照常提醒
        if StockAlertCenter.shared.isSuppressed(StockAlertCenter.signature(low[0])) { return }
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else { return }

        let day = Fmt.dayString(Date())
        let defaults = UserDefaults.standard
        var fresh: [StockRow] = []
        for row in low {
            let key = keyPrefix + row.id
            if defaults.string(forKey: key) == day { continue }
            defaults.set(day, forKey: key)
            fresh.append(row)
        }
        guard !fresh.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "库存预警"
        var parts: [String] = []
        for row in fresh.prefix(3) {
            parts.append(row.category.name + " 剩 " + Units.formatJin(row.qtyCentijin)
                         + " 斤（预警线 " + Units.formatJin(row.category.warnCentijin) + " 斤）")
        }
        content.body = parts.joined(separator: "；") + (fresh.count > 3 ? " 等 \(fresh.count) 个品类" : "")
        content.sound = .default
        content.badge = NSNumber(value: fresh.count)

        let request = UNNotificationRequest(identifier: "lowstock-" + day + "-" + UUID().uuidString,
                                            content: content, trigger: nil)
        try? await center.add(request)
    }
}
