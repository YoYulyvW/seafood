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

    @Published private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    func show(_ text: String, kind: ToastMessage.Kind = .info) {
        dismissTask?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            current = ToastMessage(text: text, kind: kind)
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                current = nil
            }
        }
    }
}

private struct ToastOverlay: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    HStack(spacing: Theme.s2) {
                        Image(systemName: symbol(for: toast.kind))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent(for: toast.kind))
                        Text(toast.text)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.surface)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, Theme.s4)
                    .padding(.vertical, Theme.s3)
                    .background(Theme.ink.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(accent(for: toast.kind).opacity(0.7), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, Theme.s5)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: center.current)
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
    func toastOverlay() -> some View { modifier(ToastOverlay()) }
}
