import SwiftUI

/// 统一分段控件：替代系统 Segmented（系统灰底和纸色主题打架）。
struct InkSegmented: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    guard selection != option.value else { return }
                    selection = option.value
                    Haptic.tap()
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selection == option.value ? Theme.surface : Theme.ink2)
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selection == option.value ? Theme.ink : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.ruleSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
