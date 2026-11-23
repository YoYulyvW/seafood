import SwiftUI
import AudioToolbox

/// 库存告警：顶部细条 + 提示音。
/// 关闭只静默"这一条"（同一品类、同一库存数值）1 小时；库存再往下掉就是新告警，会再提醒。
@MainActor
final class StockAlertCenter: ObservableObject {
    static let shared = StockAlertCenter()

    @Published private(set) var lowItems: [StockRow] = []

    private let snoozeKey = "stock_alert_snooze_until"
    private let signatureKey = "stock_alert_snooze_signature"

    static func signature(_ row: StockRow) -> String {
        row.id + ":" + String(row.qtyCentijin)
    }

    private var snoozeUntilMillis: Int64 {
        Int64(UserDefaults.standard.double(forKey: snoozeKey) * 1000)
    }

    private var snoozedSignature: String {
        UserDefaults.standard.string(forKey: signatureKey) ?? ""
    }

    /// 这条告警是不是刚被手动关掉过。
    func isSuppressed(_ signature: String) -> Bool {
        Fmt.millis() < snoozeUntilMillis && snoozedSignature == signature
    }

    var isSnoozed: Bool { Fmt.millis() < snoozeUntilMillis }

    func refresh(playSound: Bool = true) {
        let low = SQLiteStore.shared.stock().filter { $0.isLow }
        let hadAlert = !lowItems.isEmpty
        let visible = low.filter { !isSuppressed(Self.signature($0)) }
        lowItems = visible
        guard !visible.isEmpty else { return }
        // 之前没有告警条，或者当前这条不是被静默的那条 → 才算新告警
        let isNewAlert = !hadAlert || Self.signature(visible[0]) != Self.signature(lowItems.first ?? visible[0])
        if playSound && isNewAlert {
            Alarm.ring()
        }
    }

    /// 手动关闭：只锁当前这条 1 小时；库存数量一变就重新提醒。
    func dismiss() {
        guard let first = lowItems.first else { return }
        UserDefaults.standard.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: snoozeKey)
        UserDefaults.standard.set(Self.signature(first), forKey: signatureKey)
        lowItems = []
        Haptic.tap()
    }

    func clearSnooze() {
        UserDefaults.standard.removeObject(forKey: snoozeKey)
        UserDefaults.standard.removeObject(forKey: signatureKey)
        refresh()
    }
}

enum Alarm {
    static func ring() {
        AudioServicesPlaySystemSound(1005)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// 顶部细条告警：一行文字，整条可点，点了就关。
struct StockAlertBanner: View {
    @StateObject private var center = StockAlertCenter.shared

    var body: some View {
        Group {
            if let first = center.lowItems.first {
                Button {
                    center.dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.signal)
                        Text(headline(first))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(detail(first))
                            .font(Theme.number(11, weight: .regular))
                            .foregroundStyle(Theme.signal)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, 7)
                    .frame(minHeight: 32)
                    .background(Theme.surface)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Theme.signal.opacity(0.5)).frame(height: 1)
                    }
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.signal).frame(width: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("库存告警，" + first.category.name + "，点击关闭本小时提醒")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: center.lowItems.first?.id)
    }

    private func headline(_ row: StockRow) -> String {
        if center.lowItems.count > 1 {
            return row.category.name + " 等 " + String(center.lowItems.count) + " 项偏低"
        }
        return row.category.name
    }

    private func detail(_ row: StockRow) -> String {
        "剩 " + Units.formatJin(row.qtyCentijin) + " 斤 / 预警 " + Units.formatJin(row.category.warnCentijin) + " 斤"
    }
}
