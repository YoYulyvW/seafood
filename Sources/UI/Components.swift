import SwiftUI
import UIKit

// MARK: - 触感反馈（iOS 16 没有 SwiftUI 原生触感修饰符，用 UIKit 包一层）

enum Haptic {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - 通用工具

/// 把任意 Error 变成可直接显示的中文文本（InventoryError 优先走 errorDescription）。
func uiErrorText(_ error: Error) -> String {
    if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
        return text
    }
    return error.localizedDescription
}

/// 字节数 → 人类可读（安装包大小用）。
enum ByteSize {
    static func text(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 重量单位（斤 / 公斤）

enum WeightUnit: String, CaseIterable, Identifiable {
    case jin
    case kg

    var id: String { rawValue }

    var label: String { self == .jin ? "斤" : "公斤" }

    var prompt: String { self == .jin ? "输入重量（斤）" : "输入重量（公斤）" }

    /// 文本 → 厘斤（0.01 斤）。只做解析，不碰浮点存储。
    func centijin(from text: String) -> Int? {
        let cleaned = text
            .replacingOccurrences(of: "公斤", with: "")
            .replacingOccurrences(of: "千克", with: "")
            .replacingOccurrences(of: "kg", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "斤", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value > 0 else { return nil }
        let jin = self == .kg ? value * 2 : value
        let centijin = Units.centijin(fromJin: jin)
        return centijin > 0 ? centijin : nil
    }

    /// 输入折算提示。
    func hint(_ centijin: Int) -> String {
        self == .kg ? "= \(Units.formatJin(centijin)) 斤（1 公斤 = 2 斤）" : "= \(Units.formatJin(centijin)) 斤"
    }
}

// MARK: - 存储方式配色

extension StorageKind {
    /// 冰鲜偏冷灰蓝、冷冻偏墨、活鲜偏玉青。
    var uiTint: Color {
        switch self {
        case .chilled: return Theme.ice
        case .frozen: return Theme.ink2
        case .live: return Theme.jade
        }
    }
}

struct StorageTag: View {
    let storage: StorageKind

    var body: some View {
        Tag(text: storage.label, color: storage.uiTint)
    }
}

// MARK: - 基础排版

struct CardTitle: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Theme.label())
            .tracking(1.5)
            .foregroundStyle(Theme.ink3)
    }
}

/// 1px 横线，替代 Divider 统一色调。
struct RuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.ruleSoft)
            .frame(height: 1)
    }
}

/// 磅单虚线（每 1 斤一格那种感觉，这里只做视觉分隔）。
struct DottedRule: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0.5))
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0.5))
            }
            .stroke(Theme.ruleSoft, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder var content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.label())
                .foregroundStyle(Theme.ink3)
            content
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// 输入框外观：纸色底 + 细描边 + 10 圆角。
struct InkFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Theme.paper.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.ruleSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

extension View {
    func inkField() -> some View {
        modifier(InkFieldStyle())
    }
}

/// 卡片行：去掉 List 背景与分隔线，只留卡片本身。
struct CardRowModifier: ViewModifier {
    var top: CGFloat = 5
    var bottom: CGFloat = 5

    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: Theme.s4, bottom: bottom, trailing: Theme.s4))
    }
}

extension View {
    func cardRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        modifier(CardRowModifier(top: top, bottom: bottom))
    }

    /// 平铺行：纸面卡片感（行背景 surface + 细分隔线）。
    func flatRow() -> some View {
        self
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(Theme.ruleSoft)
            .listRowInsets(EdgeInsets(top: 10, leading: Theme.s4, bottom: 10, trailing: Theme.s4))
    }
}

// MARK: - 控件

struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.surface : Theme.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? Theme.ink : Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isOn ? Theme.ink : Theme.ruleSoft, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 朱红印章，旋转 -5°。
struct StampView: View {
    let text: String
    var color: Color = Theme.signal

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.8), lineWidth: 1.5)
            )
            .rotationEffect(.degrees(-5))
            .fixedSize()
    }
}

struct ErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.signal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyHint: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24, weight: .ultraLight))
                .foregroundStyle(Theme.ink3)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.s6)
    }
}

struct KVLine: View {
    let title: String
    let value: String
    var valueColor: Color = Theme.ink2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: Theme.s2)
            Text(value)
                .font(Theme.number(13, weight: .medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// 大数字块：标题 + 数字 + 单位。
struct DeltaBlock: View {
    let title: String
    let value: String
    var unit: String = "斤"
    var color: Color = Theme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.label())
                .foregroundStyle(Theme.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.number(22))
                    .foregroundStyle(color)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
            }
        }
    }
}

struct ProgressTrack: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.ruleSoft)
                Capsule()
                    .fill(Theme.signal)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
