import SwiftUI

/// 入库页：选品类（或新建）→ 重量（斤/公斤）→ 单价 → 供应商/产地/备注 → 提交。
struct InboundView: View {
    /// 作为 sheet 弹出时由外部提供 NavigationStack。
    var embedded: Bool

    /// 显式 init：其余存储属性都有默认值，只有 embedded 需要外部传入。
    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    @State private var categories: [Category] = []
    @State private var selectedID: String? = nil
    @State private var newMode = false
    @State private var newName = ""
    @State private var storage: StorageKind = .chilled
    @State private var weightText = ""
    @State private var unit: WeightUnit = .jin
    @State private var costText = ""
    @State private var supplier = ""
    @State private var showSupplierHistory = false
    @State private var origin = ""
    @State private var note = ""
    @State private var errorText: String? = nil
    @State private var result: InboundResult? = nil
    @State private var consecCount = 0
    /// 远程版才自动同步；本地版不联网。
    @AppStorage("app_mode") private var appMode = ""

    @State private var submitting = false
    @FocusState private var focus: Field?
    private enum Field: Hashable {
        case weight
        case cost
        case supplier
        case origin
        case note
        case newName
    }

    var body: some View {
        Group {
            if embedded {
                page
            } else {
                NavigationStack {
                    page
                        .navigationTitle("入库")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    // MARK: - 页面

    private var page: some View {
        ScrollView {
            VStack(spacing: Theme.s3) {
                categoryCard
                weightCard
                detailCard
                submitCard
                if let result {
                    resultCard(result)
                        .transition(.opacity)
                }
            }
            .padding(Theme.s4)
            .padding(.bottom, Theme.s6)
        }
        .scrollDismissesKeyboard(.interactively)

        .background(PaperBackground())
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focus = nil }
            }
        }
        .onAppear { loadCategories() }
    }

    // MARK: - 品类

    private var currentCategoryLabel: String {
        if newMode { return "新建品类" }
        guard let id = selectedID, let cat = categories.first(where: { $0.id == id }) else { return "选择品类" }
        return "\(cat.name) · \(cat.storage.label)"
    }

    private var categoryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                CardTitle("品类")
                Menu {
                    ForEach(categories) { cat in
                        Button {
                            selectedID = cat.id
                            newMode = false
                        } label: {
                            Text("\(cat.name) · \(cat.storage.label)")
                        }
                    }
                    Divider()
                    Button {
                        newMode = true
                        selectedID = nil
                    } label: {
                        Label("＋ 新建品类", systemImage: "plus")
                    }
                } label: {
                    HStack(spacing: Theme.s2) {
                        Text(currentCategoryLabel)
                            .font(.body)
                            .foregroundStyle(newMode ? Theme.signal : Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                    .inkField()
                }

                if newMode {
                    LabeledField("新品类名") {
                        TextField("例如：东星斑", text: $newName)
                            .focused($focus, equals: .newName)
                            .submitLabel(.done)
                            .inkField()
                    }
                    LabeledField("存储方式") {
                        Picker("存储方式", selection: $storage) {
                            ForEach(StorageKind.allCases) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    // MARK: - 重量与单价

    private var weightCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack {
                    CardTitle("重量")
                    Spacer()
                    Picker("单位", selection: $unit) {
                        ForEach(WeightUnit.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 118)
                }

                TextField(unit.prompt, text: $weightText)
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .weight)
                    .inkField()
                    .font(Theme.number(26))

                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Text(convertedHint)
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: Theme.s2)
                    Text("金额 \(amountText)")
                        .font(Theme.number(13))
                        .foregroundStyle(Theme.ink2)
                }

                RuleDivider()

                LabeledField("单价（元/斤）") {
                    HStack(spacing: Theme.s2) {
                        TextField("0.00", text: $costText)
                            .keyboardType(.decimalPad)
                            .focused($focus, equals: .cost)
                            .inkField()
                        Text("元/斤")
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
    }

    private var convertedHint: String {
        guard let centijin = unit.centijin(from: weightText) else {
            return "1 公斤 = 2 斤，可只输数字"
        }
        return unit.hint(centijin)
    }

    private var amountText: String {
        guard let centijin = unit.centijin(from: weightText) else { return "—" }
        let priceCent = parseCostCent()
        guard priceCent > 0 else { return "—" }
        return Units.formatYuan(centijin * priceCent / 100)
    }

    private func parseCostCent() -> Int {
        let cleaned = costText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value >= 0 else { return 0 }
        return Units.cent(fromYuan: value)
    }

    // MARK: - 供应商 / 产地 / 备注

    private var detailCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                CardTitle("来源")
                LabeledField("供应商") {
                    HStack(spacing: Theme.s2) {
                        TextField("例如：北海", text: $supplier)
                            .focused($focus, equals: .supplier)
                            .inkField()
                        Button {
                            showSupplierHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.signal)
                                .frame(width: 44, height: 44)
                                .background(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                        .stroke(Theme.ruleSoft, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        }
                        .accessibilityLabel("选择历史供应商")
                        .sheet(isPresented: $showSupplierHistory) {
                            PartyHistorySheet(title: "历史供应商",
                                              names: SQLiteStore.shared.partyNames("supplier")) { picked in
                                supplier = picked
                            }
                        }
                    }
                }
                LabeledField("产地") {
                    TextField("例如：北海", text: $origin)
                        .focused($focus, equals: .origin)
                        .inkField()
                }
                LabeledField("备注") {
                    TextField("可留空", text: $note)
                        .focused($focus, equals: .note)
                        .inkField()
                }
            }
        }
    }

    // MARK: - 提交

    private var submitCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                if let errorText {
                    ErrorLine(text: errorText)
                }

                Button {
                    submit()
                } label: {
                    Text(submitting ? "提交中…" : "提交入库")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(submitting)

                HStack(spacing: Theme.s2) {
                    Text("本次已连续录入 \(consecCount) 单")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: Theme.s2)
                    Button("清空") { clearAll() }
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    private func resultCard(_ res: InboundResult) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s2) {
                HStack {
                    CardTitle("入库成功")
                    Spacer(minLength: Theme.s2)
                    StampView(text: "已入账", color: Theme.jade)
                }
                KVLine(title: "单号", value: res.docNo)
                KVLine(title: "批次", value: res.batchNo)
                KVLine(title: "数量", value: Units.formatJinUnit(res.centijin), valueColor: Theme.ink)
                KVLine(title: "金额", value: Units.formatYuan(res.amountCent), valueColor: Theme.jade)
            }
        }
    }

    // MARK: - 动作

    private func loadCategories() {
        categories = SQLiteStore.shared.categories()
        if selectedID == nil, !newMode, let first = categories.first {
            selectedID = first.id
        }
    }

    private func clearAll() {
        weightText = ""
        costText = ""
        supplier = ""
        origin = ""
        note = ""
        newName = ""
        errorText = nil
        result = nil
        focus = nil
    }

    private func submit() {
        errorText = nil
        focus = nil

        guard let centijin = unit.centijin(from: weightText) else {
            setError("请输入有效重量（大于 0）")
            return
        }
        if newMode {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                setError("请填写新品类名")
                return
            }
        } else if selectedID == nil {
            setError("请选择品类")
            return
        }
        let costYuan = Double(costText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard costYuan >= 0 else {
            setError("单价不能为负")
            return
        }

        submitting = true
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSupplier = supplier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let res = try SQLiteStore.shared.inbound(
                categoryID: newMode ? nil : selectedID,
                newCategoryName: newMode ? trimmedName : nil,
                storage: storage,
                jin: Double(centijin) / 100,
                unitCost: costYuan,
                supplier: trimmedSupplier,
                origin: trimmedOrigin,
                note: trimmedNote
            )
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                result = res
            }
            consecCount += 1
            weightText = ""
            errorText = nil
            Haptic.success()
            SQLiteStore.shared.addPartyName("supplier", trimmedSupplier)
            ToastCenter.shared.show("入库成功 · " + res.docNo, kind: .success)
            loadCategories()
            if newMode,
               let created = categories.first(where: { $0.name == trimmedName }) {
                selectedID = created.id
                newMode = false
                newName = ""
            }
            Task { @MainActor in
                SyncEngine.shared.autoSyncAfterWrite()
            }
        } catch {
            setError(uiErrorText(error))
        }
        submitting = false
    }

    private func setError(_ text: String) {
        withAnimation(.easeOut(duration: 0.16)) { errorText = text }
        Haptic.warning()
    }
}
