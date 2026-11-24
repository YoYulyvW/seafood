import SwiftUI

/// 某个品类的在库批次列表，长按品类进入。
struct BatchListView: View {
    let category: Category

    @State private var batches: [Batch] = []
    @State private var editing: Batch?

    var body: some View {
        List {
            Section {
                if batches.isEmpty {
                    Text("这个品类目前没有在库批次")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink3)
                        .listRowBackground(Theme.surface)
                }
                ForEach(batches) { batch in
                    Button {
                        editing = batch
                    } label: {
                        HStack(spacing: Theme.s3) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(batch.batchNo)
                                    .font(Theme.number(14))
                                    .foregroundStyle(Theme.ink)
                                HStack(spacing: 8) {
                                    if !batch.supplier.isEmpty { Text(batch.supplier) }
                                    Text(Fmt.dayTimeString(batch.receivedAt))
                                    Text("进价 " + Units.formatYuan(batch.unitCostCent))
                                }
                                .font(.caption2)
                                .foregroundStyle(Theme.ink3)
                            }
                            Spacer(minLength: Theme.s2)
                            Text(Units.formatJin(batch.qtyLeftCentijin) + " 斤")
                                .font(Theme.number(16))
                                .foregroundStyle(Theme.ink)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.ink3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.surface)
                }
            } footer: {
                Text("点批次可以校正数量、归属品类、来源；每次校正都会写一条审计日志。")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        .navigationTitle(category.name + " · 批次")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(item: $editing) { batch in
            NavigationStack {
                BatchEditView(batch: batch,
                              categories: SQLiteStore.shared.categories(includeInactive: true)) {
                    reload()
                }
            }
        }
    }

    private func reload() {
        batches = SQLiteStore.shared.batches(categoryID: category.id)
    }
}

/// 单批次校正：数量/归属品类/来源备注 + 必填原因，保存后写审计。
struct BatchEditView: View {
    let batch: Batch
    let categories: [Category]
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var qtyText = ""
    @State private var categoryID = ""
    @State private var supplier = ""
    @State private var origin = ""
    @State private var note = ""
    @State private var reason = ""
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s3) {
                Card {
                    VStack(alignment: .leading, spacing: Theme.s2) {
                        Text("批次 " + batch.batchNo)
                            .font(Theme.number(15))
                            .foregroundStyle(Theme.ink)
                        Text("进价 " + Units.formatYuan(batch.unitCostCent) + " · 入库 " + Fmt.dayTimeString(batch.receivedAt))
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: Theme.s3) {
                        Text("校正内容")
                            .font(Theme.label())
                            .foregroundStyle(Theme.ink3)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("归属品类").font(.caption).foregroundStyle(Theme.ink3)
                            Menu {
                                ForEach(categories) { cat in
                                    Button(cat.name) { categoryID = cat.id }
                                }
                            } label: {
                                HStack {
                                    Text(categories.first(where: { $0.id == categoryID })?.name ?? "选择品类")
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.ink3)
                                }
                                .inkField()
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("剩余重量（斤）").font(.caption).foregroundStyle(Theme.ink3)
                            TextField("如 12.5", text: $qtyText)
                                .keyboardType(.decimalPad)
                                .inkField()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("供应商").font(.caption).foregroundStyle(Theme.ink3)
                            TextField("供应商", text: $supplier).inkField()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("产地").font(.caption).foregroundStyle(Theme.ink3)
                            TextField("产地", text: $origin).inkField()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("备注").font(.caption).foregroundStyle(Theme.ink3)
                            TextField("备注", text: $note).inkField()
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("校正原因（必填，会写进审计日志）")
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                        TextField("例如：入库时把 20 斤记成 200 斤", text: $reason)
                            .inkField()
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(Theme.signal)
                }

                Button {
                    save()
                } label: {
                    Text("保存校正")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(Theme.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PaperBackground())
        .navigationTitle("校正批次")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        categoryID = batch.categoryID
        qtyText = Units.formatJin(batch.qtyLeftCentijin)
        supplier = batch.supplier
        origin = batch.origin
        note = batch.note
    }

    private func save() {
        guard let jin = Units.parseJin(qtyText) else {
            errorText = "重量填数字，比如 12.5"
            return
        }
        let input = SQLiteStore.BatchCorrection(
            batchID: batch.id,
            newCategoryID: categoryID,
            newQtyCentijin: Units.centijin(fromJin: jin),
            supplier: supplier,
            origin: origin,
            note: note,
            reason: reason,
            operatorName: SQLiteStore.shared.setting("operator")
        )
        do {
            try SQLiteStore.shared.correctBatch(input)
            StockAlertCenter.shared.refresh()
            ToastCenter.shared.show("批次已校正，已留痕", kind: .success)
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
