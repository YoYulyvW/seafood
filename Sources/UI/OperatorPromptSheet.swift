import SwiftUI

enum OperatorNames {
    private static let seeds = ["阿海", "小林", "阿强", "老陈", "大梁", "阿波", "阿霞", "小周", "阿明", "阿兰"]

    /// 留空时给一个随机操作员名，便于留痕追溯。
    static func random() -> String {
        let base = seeds.randomElement() ?? "操作员"
        return base + "-" + String(UUID().uuidString.prefix(3)).uppercased()
    }
}

/// 操作员录入：首次安装、存量设备补名字、入库前兜底都用它。
struct OperatorPromptSheet: View {
    var onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    Text("填一个名字，之后的入库、出库、批次校正都会记在这个名字下；留空会随机生成一个。")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)

                    Card {
                        VStack(alignment: .leading, spacing: Theme.s2) {
                            Text("操作员")
                                .font(Theme.label())
                                .foregroundStyle(Theme.ink3)
                            TextField("例如：阿海", text: $name)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .inkField()
                        }
                    }

                    Button {
                        save(name)
                    } label: {
                        Text("用这个名字")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        save(OperatorNames.random())
                    } label: {
                        Text("随机一个")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(Theme.s4)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(PaperBackground())
            .navigationTitle("设置操作员")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func save(_ raw: String) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = OperatorNames.random() }
        SQLiteStore.shared.setSetting("operator", value)
        Haptic.success()
        onSaved(value)
        dismiss()
    }
}
