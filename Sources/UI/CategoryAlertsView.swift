import SwiftUI

/// 品类与预警：维护存储方式、预警线、允许负库存。
struct CategoryAlertsView: View {
    @State private var categories: [Category] = []
    @State private var editing: Category?
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        List {
            Section {
                ForEach(categories) { cat in
                    Button {
                        editing = cat
                    } label: {
                        HStack(spacing: Theme.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Theme.s2) {
                                    Text(cat.name)
                                        .foregroundStyle(Theme.ink)
                                    Tag(text: cat.storage.label, color: cat.storage == .frozen ? Theme.ice : Theme.jade)
                                    if !cat.active {
                                        Tag(text: "停用", color: Theme.ink3)
                                    }
                                }
                                Text(warnText(cat))
                                    .font(.caption)
                                    .foregroundStyle(cat.warnCentijin > 0 ? Theme.ink2 : Theme.ink3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.ink3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
                }
            } footer: {
                Text("预警线以下的品类会出现在库存页并触发低库存通知；允许负库存只对活鲜估重这类场景打开。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        .tint(Theme.signal)
        .navigationTitle("品类与预警")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { cat in
            CategoryEditor(category: cat) { reload() }
        }
        .sheet(isPresented: $adding) {
            CategoryEditor(category: nil) { reload() }
        }
        .alert("操作失败", isPresented: Binding(get: { errorText != nil },
                                              set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func warnText(_ cat: Category) -> String {
        if cat.warnCentijin > 0 {
            return "预警线 " + Units.formatJin(cat.warnCentijin) + " 斤" + (cat.allowNegative ? " · 允许负库存" : "")
        }
        return cat.allowNegative ? "未设预警线 · 允许负库存" : "未设预警线"
    }

    private func reload() {
        categories = SQLiteStore.shared.categories(includeInactive: true)
    }
}

/// 新建 / 编辑单个品类。
private struct CategoryEditor: View {
    let category: Category?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var storage: StorageKind = .chilled
    @State private var warnText = ""
    @State private var allowNegative = false
    @State private var active = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基本") {

                    TextField("品类名", text: $name)
                    Picker("存储方式", selection: $storage) {
                        ForEach(StorageKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }
                Section {
                    TextField("留空表示不预警", text: $warnText)
                        .keyboardType(.decimalPad)
                    Toggle("允许负库存", isOn: $allowNegative)
                    if category != nil {
                        Toggle("启用", isOn: $active)
                    }
                } header: {
                    Text("预警")
                } footer: {
                    Text("库存低于预警线时，库存页标红并推送一次通知（同一品类每天最多一次）。")
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(Theme.signal)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .tint(Theme.signal)
            .navigationTitle(category == nil ? "新建品类" : "编辑品类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let category else {
            warnText = "20"
            return
        }
        name = category.name
        storage = category.storage
        warnText = category.warnCentijin > 0 ? Units.formatJin(category.warnCentijin) : ""
        allowNegative = category.allowNegative
        active = category.active
    }

    private func save() {
        let warn = warnText.isEmpty ? 0 : (Units.parseJin(warnText) ?? -1)
        if warn < 0 {
            errorText = "预警线要填数字，或留空"
            return
        }
        do {
            if var cat = category {
                cat.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cat.name : name
                cat.storage = storage
                cat.warnCentijin = Units.centijin(fromJin: warn)
                cat.allowNegative = allowNegative
                cat.active = active
                cat.updatedAt = Fmt.millis()
                try SQLiteStore.shared.upsertCategory(cat)
            } else {
                _ = try SQLiteStore.shared.createCategory(name: name, storage: storage,
                                                          warnJin: warn, allowNegative: allowNegative)
            }
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
