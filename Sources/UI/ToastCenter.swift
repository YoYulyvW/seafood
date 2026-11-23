import SwiftUI

struct ToastMessage: Identifiable, Equatable {
    enum Kind {
        case info, success, error
    }
    let id = UUID()
    var text: String
    var kind: Kind = .info
}

/// 全局轻提示：底部浮一条，2 秒自动消失，不打断输入。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published fileprivate(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, kind: ToastMessage.Kind = .info) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            current = ToastMessage(text: text, kind: kind)
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                current = nil
            }
        }
    }
}

/// 真正订阅 ToastCenter 的宿主视图。
/// 注意：不能把 @ObservedObject 直接写在 ViewModifier 上——它不是 View，
/// 不会进入视图图里，@Published 变化收不到，这就是之前 toast 一直不出现的原因。
private struct ToastHost: View {
    @StateObject private var center = ToastCenter.shared

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let toast = center.current {
                HStack(spacing: Theme.s2) {
                    Image(systemName: symbol(for: toast.kind))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent(for: toast.kind))
                    Text(toast.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.surface)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
                .background(Theme.ink.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent(for: toast.kind).opacity(0.75), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Theme.ink.opacity(0.22), radius: 12, x: 0, y: 6)
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: center.current)
        .allowsHitTesting(false)
    }

    private func symbol(for kind: ToastMessage.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private func accent(for kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .info: return Theme.rule
        case .success: return Theme.jade
        case .error: return Theme.signal
        }
    }
}

extension View {
    func toastOverlay() -> some View {
        overlay(alignment: .bottom) {
            ToastHost()
        }
    }
}
