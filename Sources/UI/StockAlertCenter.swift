import SwiftUI
import AudioToolbox

/// 库存告警：顶部长期浮标 + 提示音，手动关闭后 1 小时内不再响。
@MainActor
final class StockAlertCenter: ObservableObject {
    static let shared = StockAlertCenter()

    @Published private(set) var lowItems: [StockRow] = []

    private let snoozeKey = "stock_alert_snooze_until"

    private var snoozeUntilMillis: Int64 {
        Int64(UserDefaults.standard.double(forKey: snoozeKey) * 1000)
    }

    var isSnoozed: Bool {
        Fmt.millis() < snoozeUntilMillis
    }

    var snoozeRemainMinutes: Int {
        max(0, Int((snoozeUntilMillis - Fmt.millis()) / 60000))
    }

    /// 重新读一次库存；新出现的告警才响铃。
    func refresh(playSound: Bool = true) {
        let low = SQLiteStore.shared.stock().filter { $0.isLow }
        let hadAlert = !lowItems.isEmpty
        lowItems = isSnoozed ? [] : low
        guard !low.isEmpty, !isSnoozed else { return }
        if !hadAlert && playSound {
            Alarm.ring()
        }
    }

    /// 手动关闭：清掉浮标，并锁定 1 小时。
    func dismissForAnHour() {
        let until = Date().addingTimeInterval(3600)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: snoozeKey)
        lowItems = []
        Haptic.tap()
    }

    func clearSnooze() {
        UserDefaults.standard.removeObject(forKey: snoozeKey)
        refresh()
    }
}

enum Alarm {
    /// 系统提示音 + 震动；无需额外音频文件，静音开关下也会震动提示。
    static func ring() {
        AudioServicesPlaySystemSound(1005)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// 顶部长期浮标：一直挂在内容上方，显示最紧急的那个品类。
struct StockAlertBanner: View {
    @StateObject private var center = StockAlertCenter.shared

    var body: some View {
        Group {
            if let first = center.lowItems.first {
                HStack(spacing: Theme.s2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.signal)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(alertTitle(first))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(alertDetail(first))
                            .font(Theme.number(11, weight: .regular))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Theme.s2)

                    Button {
                        center.dismissForAnHour()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭告警，一小时内不再提示")
                }
                .padding(.leading, Theme.s4)
                .padding(.trailing, Theme.s1)
                .padding(.vertical, Theme.s1)
                .background(Theme.surface)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.signal.opacity(0.55))
                        .frame(height: 1)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.signal)
                        .frame(width: 3)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: center.lowItems.first?.id)
    }

    private func alertTitle(_ row: StockRow) -> String {
        if center.lowItems.count > 1 {
            return "库存告警 · " + row.category.name + " 等 " + String(center.lowItems.count) + " 个品类偏低"
        }
        return "库存告警 · " + row.category.name
    }

    private func alertDetail(_ row: StockRow) -> String {
        let stock = Units.formatJin(row.qtyCentijin)
        let warn = Units.formatJin(row.category.warnCentijin)
        var text = "剩 " + stock + " 斤，预警线 " + warn + " 斤"
        if center.lowItems.count > 1 {
            text = row.category.name + " " + text
        }
        return text
    }
}
