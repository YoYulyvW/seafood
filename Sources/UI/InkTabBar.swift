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
    private let pillInset: CGFloat = 4                   // 左右各留 4，选中块宽度 = 项宽 - 8
    private var pillHeight: CGFloat { itemHeight - 4 }   // 48：上下各 7，居中对称

    @State private var dragStartIndex: Int = 0
    @State private var pillIndex: CGFloat = 0
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
                    .offset(x: leading + pillOffset(itemWidth: itemWidth) + pillInset,
                            y: 0)

                HStack(spacing: 0) {
                    ForEach(titles.indices, id: \.self) { i in
                        tabItem(i)
                            .frame(width: itemWidth, height: itemHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(springCurve) {
                                    pillIndex = CGFloat(i)
                                    index = i
                                }
                                Haptic.tap()
                            }
                    }
                }
                .padding(.leading, leading)
            }
            .frame(width: geo.size.width, height: barHeight)
            // 真正的玻璃容器：只有材质本身的折射，没有白色铺底、没有投影，
            // 这样它才是"浮在页面上的一层玻璃"，而不是一块和背景同色的实块。
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        // 一层很淡的纸色，保证在浅色页面上也能看出"有一条"
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Theme.surface.opacity(0.35))
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.42), lineWidth: 0.8)
            )
            .shadow(color: Theme.ink.opacity(0.10), radius: 12, x: 0, y: 6)
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture(itemWidth: itemWidth))
        }
        .frame(height: barHeight)
        .onAppear { pillIndex = CGFloat(index) }
        .onChange(of: index) { value in
            if !isDragging {
                withAnimation(springCurve) { pillIndex = CGFloat(value) }
            }
        }
    }

    // MARK: - 组件

    /// 选中项展开成「图标 + 文字」的胶囊内容，其它项只留图标；
    /// 切换时文字淡入、图标轻微回弹，和教程里那种悬浮条的节奏一致。
    private func tabItem(_ i: Int) -> some View {
        let selected = index == i
        return HStack(spacing: 5) {
            Image(systemName: icons[i])
                .font(.system(size: selected ? 20 : 22, weight: .medium))
                .scaleEffect(selected ? 1.0 : 0.96)
            if selected {
                Text(titles[i])
                    .font(.system(size: 12, weight: .semibold))
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)).combined(with: .scale(scale: 0.9)),
                            removal: .opacity.combined(with: .scale(scale: 0.9))
                        )
                    )
            }
        }
        .foregroundStyle(selected ? Theme.ink : Theme.ink3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(springCurve, value: index)
    }

    /// 只有选中项这一块是玻璃：材质折射 + 顶部高光 + 细描边 + 柔和落影。
    private func glassPill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.14))
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
            .frame(width: width, height: pillHeight)
            .shadow(color: Theme.ink.opacity(0.06), radius: 4, x: 0, y: 1)
            .animation(springCurve, value: index)
    }

    // MARK: - 位置与拖拽

    /// 未拖动时吸在 index 上；拖动时跟随手指，松手吸附到最近的一格。
    private func pillOffset(itemWidth: CGFloat) -> CGFloat {
        let raw: CGFloat
        if isDragging {
            raw = CGFloat(dragStartIndex) * itemWidth + dragTranslation
        } else {
            raw = pillIndex * itemWidth
        }
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
                let clamped = min(max(Int((raw / itemWidth).rounded()), 0), titles.count - 1)
                // 先把块钉在手指松开的位置（不带动画），再从这里吸到目标格，
                // 避免 @GestureState 归零造成"先弹回原位再滑过去"的顿挫。
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pillIndex = min(max(raw / itemWidth, 0), CGFloat(titles.count - 1))
                    isDragging = false
                }
                withAnimation(springCurve) {
                    pillIndex = CGFloat(clamped)
                    index = clamped
                }
                Haptic.tap()
            }
    }
}
