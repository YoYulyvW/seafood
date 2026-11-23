import SwiftUI

/// 设计基调：水产批发市场的过磅单 —— 纸色底、墨线、等宽数字、朱红印章。
enum Theme {
    static let paper = Color(hex: 0xF1EDE1)
    static let surface = Color(hex: 0xFAF7EF)
    static let ink = Color(hex: 0x16191B)
    static let ink2 = Color(hex: 0x474C4F)
    static let ink3 = Color(hex: 0x767B78)
    static let rule = Color(hex: 0xC7C0AC)
    static let ruleSoft = Color(hex: 0xDBD4C1)
    static let signal = Color(hex: 0xBF3A28)
    static let jade = Color(hex: 0x1D5C4E)
    static let ice = Color(hex: 0x8FAEB6)

    static let radius: CGFloat = 10
    static let cardRadius: CGFloat = 14

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    static func title(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func label() -> Font { .system(size: 12, weight: .medium) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 纸色底 + 极淡横纹，接近磅单纸。
struct PaperBackground: View {
    var body: some View {
        ZStack {
            Theme.paper
            GeometryReader { proxy in
                Path { path in
                    var y: CGFloat = 0
                    while y < proxy.size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                        y += 4
                    }
                }
                .stroke(Theme.ink.opacity(0.02), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = Theme.s4
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.ruleSoft, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct Tag: View {
    let text: String
    var color: Color = Theme.jade

    var body: some View {
        Text(text)
            .font(Theme.label())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.55), lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.surface)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.ink)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.signal)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.signal, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
