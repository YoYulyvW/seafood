import SwiftUI

/// 自定义底部标签栏：整条高 62、左右留 20、离底部指示条 21、每项 82×52（窄屏自动等比收窄）。
/// 选中态是一块可以按住拖动的圆角玻璃块，切换用 600ms 弹簧曲线。
struct InkTabBar: View {
    @Binding var index: Int
    let titles: [String]
    let icons: [String]

    private let barHeight: CGFloat = 62
    private let itemHeight: CGFloat = 52
    private let maxItemWidth: CGFloat = 82
    private let pillInset: CGFloat = 5

    @State private var dragStartIndex: Int = 0
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    private var springCurve: Animation { .spring(response: 0.6, dampingFraction: 0.72) }

    var body: some View {
        GeometryReader { geo in
            let count = max(titles.count, 1)
            let itemWidth = min(maxItemWidth, geo.size.width / CGFloat(count))
            let contentWidth = itemWidth * CGFloat(count)
            let leading = (geo.size.width - contentWidth) / 2
            let pillWidth = itemWidth - pillInset * 2

            ZStack(alignment: .leading) {
                glassPill(width: pillWidth)
                    .offset(x: leading + pillOffset(itemWidth: itemWidth) + pillInset, y: pillInset)

                HStack(spacing: 0) {
                    ForEach(titles.indices, id: \.self) { i in
                        tabItem(i)
                            .frame(width: itemWidth, height: itemHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(springCurve) { index = i }
                                Haptic.tap()
                            }
                    }
                }
                .padding(.leading, leading)
            }
            .frame(width: geo.size.width, height: barHeight)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: Theme.ink.opacity(0.12), radius: 16, x: 0, y: 8)
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture(itemWidth: itemWidth))
        }
        .frame(height: barHeight)
    }

    // MARK: - 组件

    private func tabItem(_ i: Int) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icons[i])
                .font(.system(size: 17, weight: .medium))
            Text(titles[i])
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(index == i ? Theme.ink : Theme.ink3)
        .animation(springCurve, value: index)
    }

    /// 只有选中项这一块是玻璃：材质折射 + 顶部高光 + 细描边 + 柔和落影。
    private func glassPill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.42), Color.white.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.65), Color.white.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .overlay(
                // 贴边的一圈内高光，模拟玻璃折射的亮边
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .inset(by: 1.5)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            )
            .frame(width: width, height: itemHeight - pillInset * 2)
            .shadow(color: Theme.ink.opacity(0.14), radius: 10, x: 0, y: 4)
            .shadow(color: Theme.ink.opacity(0.06), radius: 2, x: 0, y: 1)
            .animation(springCurve, value: index)
    }

    // MARK: - 位置与拖拽

    /// 未拖动时吸在 index 上；拖动时跟随手指，松手吸附到最近的一格。
    private func pillOffset(itemWidth: CGFloat) -> CGFloat {
        let base = CGFloat(index) * itemWidth
        guard isDragging else { return base }
        let raw = CGFloat(dragStartIndex) * itemWidth + dragTranslation
        let minX: CGFloat = 0
        let maxX = itemWidth * CGFloat(max(titles.count - 1, 0))
        return min(max(raw, minX), maxX)
    }

    private func dragGesture(itemWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation.width
            }
            .onChanged { _ in
                if !isDragging {
                    dragStartIndex = index
                    isDragging = true
                    Haptic.tap()
                }
            }
            .onEnded { value in
                let raw = CGFloat(dragStartIndex) * itemWidth + value.translation.width
                let target = Int((raw / itemWidth).rounded())
                let clamped = min(max(target, 0), titles.count - 1)
                isDragging = false
                withAnimation(springCurve) { index = clamped }
                Haptic.tap()
            }
    }
}
