import SwiftUI

/// 供应商 / 客户历史：入库出库成功后自动记名字，下次一点就填。
struct PartyHistorySheet: View {
    let title: String
    let names: [String]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if names.isEmpty {
                    EmptyHint(title: "还没有记录", detail: "填过一次并提交成功，这里就会出现")
                        .padding(Theme.s4)
                } else {
                    List {
                        ForEach(names, id: \.self) { name in
                            Button {
                                onPick(name)
                                Haptic.tap()
                                dismiss()
                            } label: {
                                HStack {
                                    Text(name)
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.ink3)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.surface)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(PaperBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
