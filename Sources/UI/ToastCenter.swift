import SwiftUI
import UIKit

struct ToastMessage: Identifiable, Equatable {
    enum Kind { case info, success, error }
    let id = UUID()
    var text: String
    var kind: Kind = .info
}

/// 全局轻提示：独立 UIWindow 承载，永远只有一条，且能盖在 sheet 之上。
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private var window: UIWindow?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, kind: ToastMessage.Kind = .info) {
        hideTask?.cancel()
        present(ToastMessage(text: text, kind: kind))
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func ensureWindow() -> UIWindow? {
        if let window { return window }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return nil }

        let host = UIHostingController(rootView: ToastBar(message: nil))
        host.view.backgroundColor = .clear

        let win = UIWindow(windowScene: scene)
        win.rootViewController = host
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear
        win.isUserInteractionEnabled = false
        win.isHidden = false
        window = win
        return win
    }

    private func present(_ message: ToastMessage) {
        guard let win = ensureWindow(),
              let host = win.rootViewController as? UIHostingController<ToastBar> else { return }
        host.rootView = ToastBar(message: message)
        win.isHidden = false
        host.view.alpha = 0
        host.view.transform = CGAffineTransform(translationX: 0, y: 12)
        UIView.animate(withDuration: 0.24, delay: 0,
                       usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4) {
            host.view.alpha = 1
            host.view.transform = .identity
        }
    }

    private func dismiss() {
        guard let win = window,
              let host = win.rootViewController as? UIHostingController<ToastBar> else { return }
        UIView.animate(withDuration: 0.2, animations: {
            host.view.alpha = 0
            host.view.transform = CGAffineTransform(translationX: 0, y: 8)
        }, completion: { _ in
            host.rootView = ToastBar(message: nil)
            win.isHidden = true
        })
    }
}

/// 浮条本身：底部一条，不接收点击。
struct ToastBar: View {
    let message: ToastMessage?

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if let message {
                HStack(spacing: Theme.s2) {
                    Image(systemName: symbol(message.kind))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent(message.kind))
                    Text(message.text)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.surface)
                        .lineLimit(2)
                }
                .padding(.horizontal, Theme.s4)
                .padding(.vertical, Theme.s3)
                .background(Theme.ink.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent(message.kind).opacity(0.75), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, Theme.s5)
                .padding(.bottom, 96)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func symbol(_ kind: ToastMessage.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        }
    }

    private func accent(_ kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .info: return Theme.rule
        case .success: return Theme.jade
        case .error: return Theme.signal
        }
    }
}
