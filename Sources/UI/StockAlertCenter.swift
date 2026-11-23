import SwiftUI
import AudioToolbox

/// 库存告警中心：按「品类 + 当前库存数值」做确认。
/// 点关闭会确认当前这一批告警，直到出现新的数值（继续掉货或新增偏低品类）才再次提醒。
@MainActor
final class StockAlertCenter: ObservableObject {
    static let shared = StockAlertCenter()

    @Published private(set) var lowItems: [StockRow] = []

    private let ackKey = "stock_alert_ack_signatures"

    static func signature(_ row: StockRow) -> String {
        row.id + ":" + String(row.qtyCentijin)
    }

    private var acknowledged: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: ackKey) ?? [])
    }

    private func storeAck(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: ackKey)
    }

    /// 有未确认的新告警就响一次。
    func refresh(playSound: Bool = true) {
        let low = SQLiteStore.shared.stock().filter { $0.isLow }
        let ack = acknowledged
        let visible = low.filter { !ack.contains(Self.signature($0)) }
        let previousTop = lowItems.first.map { Self.signature($0) }
        lowItems = visible
        guard let top = visible.first else { return }
        if playSound && previousTop != Self.signature(top) {
            Alarm.ring()
        }
    }

    /// 关闭：确认当前所有偏低品类，清空告警显示，直到数值再变。
    func acknowledgeAll() {
        let low = SQLiteStore.shared.stock().filter { $0.isLow }
        storeAck(Set(low.map { Self.signature($0) }))
        lowItems = []
        Haptic.tap()
    }

    func isAcknowledged(_ row: StockRow) -> Bool {
        acknowledged.contains(Self.signature(row))
    }

    func resetAcknowledgements() {
        UserDefaults.standard.removeObject(forKey: ackKey)
        refresh()
    }
}

enum Alarm {
    static func ring() {
        AudioServicesPlaySystemSound(1005)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// 横条样式（旧版）。
struct StockAlertBanner: View {
    @StateObject private var center = StockAlertCenter.shared

    var body: some View {
        Group {
            if let first = center.lowItems.first {
                Button {
                    center.acknowledgeAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.signal)
                        Text(first.category.name + (center.lowItems.count > 1 ? " 等 \(center.lowItems.count) 项偏低" : ""))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text("剩 " + Units.formatJin(first.qtyCentijin) + " 斤")
                            .font(Theme.number(11, weight: .regular))
                            .foregroundStyle(Theme.signal)
                        Spacer(minLength: 4)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, Theme.s3)
                    .padding(.vertical, 7)
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
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: center.lowItems.count)
    }
}

/// 气泡样式（默认）：右下角一颗小气泡，点开才展开，不占顶部空间。
struct StockAlertBubble: View {
    @StateObject private var center = StockAlertCenter.shared
    @Binding var expanded: Bool
    @AppStorage("alert_bubble_offset_x") private var savedX = 0.0
    @AppStorage("alert_bubble_offset_y") private var savedY = 0.0
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        Group {
            if let first = center.lowItems.first {
                if expanded {
                    card(first)
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                } else {
                    bubble(first)
                        .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
        }
        // 展开/数量变化的动画只作用在内容上，不要和拖拽的 offset 抢动画
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: center.lowItems.count)
        // 拖拽用 GestureState：手指移动的每一帧直接改 offset，没有动画插值，所以跟手
        .offset(x: savedX + dragOffset.width, y: savedY + dragOffset.height)
        .animation(nil, value: dragOffset)
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    var nx = savedX + value.translation.width
                    var ny = savedY + value.translation.height
                    nx = min(max(nx, -220), 40)
                    ny = min(max(ny, -520), 40)
                    savedX = nx
                    savedY = ny
                }
        )
    }

    private func bubble(_ first: StockRow) -> some View {
        Button {
            expanded = true
            Haptic.tap()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.surface)
                Text(String(center.lowItems.count))
                    .font(Theme.number(13, weight: .bold))
                    .foregroundStyle(Theme.surface)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.signal)
            .clipShape(Capsule())
            .shadow(color: Theme.ink.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("库存告警 " + first.category.name)
    }

    private func card(_ first: StockRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.signal)
                Text("库存告警")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.s2)
                Button {
                    expanded = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, Theme.s3)
            .padding(.trailing, Theme.s1)
            .padding(.top, Theme.s2)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(center.lowItems.prefix(4)) { row in
                    HStack(spacing: Theme.s2) {
                        Text(row.category.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: Theme.s2)
                        Text(Units.formatJin(row.qtyCentijin) + " 斤")
                            .font(Theme.number(12, weight: .semibold))
                            .foregroundStyle(Theme.signal)
                        Text("/ " + Units.formatJin(row.category.warnCentijin))
                            .font(Theme.number(10, weight: .regular))
                            .foregroundStyle(Theme.ink3)
                    }
                }
                if center.lowItems.count > 4 {
                    Text("另有 " + String(center.lowItems.count - 4) + " 个品类偏低")
                        .font(.caption2)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, Theme.s3)
            .padding(.top, Theme.s2)

            Divider().overlay(Theme.ruleSoft)

            Button {
                center.acknowledgeAll()
                expanded = false
            } label: {
                Text("关闭告警，直到库存再变化")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.signal)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 260)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.18), radius: 16, x: 0, y: 6)
    }
}
