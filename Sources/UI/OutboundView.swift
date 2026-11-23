import SwiftUI

/// 出库页：选品类 → 重量 → 售价 → 加入本单（可滑动删除）→ 填客户 → 提交。
struct OutboundView: View {
    /// 作为 sheet 弹出时由外部提供 NavigationStack。
    var embedded: Bool

    /// 显式 init：其余存储属性都有默认值，只有 embedded 需要外部传入。
    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    @State private var categories: [Category] = []
    @State private var stockByID: [String: Int] = [:]
    @State private var batchCountByID: [String: Int] = [:]
    @State private var selectedID: String? = nil
    @State private var weightText = ""
    @State private var unit: WeightUnit = .jin
    @State private var priceText = ""
    @State private var items: [PendingItem] = []
    @State private var customer = ""
    @State private var showCustomerHistory = false
    @State private var errorText: String? = nil
    @State private var submitting = false
    @State private var result: OutboundResult? = nil
    /// 远程版才自动同步；本地版不联网。
    @AppStorage("app_mode") private var appMode = ""

    @State private var showResult = false
    @FocusState private var focus: Field?
    private enum Field: Hashable {
        case weight
        case price
        case customer
    }

    /// 本单待提交的一条（金额按分算，不落浮点）。
    struct PendingItem: Identifiable {
        let id = UUID()
        var categoryID: String
        var categoryName: String
        var centijin: Int
        var unitPriceCent: Int

        var amountCent: Int { centijin * unitPriceCent / 100 }
    }

    private var totalCentijin: Int { items.reduce(0) { $0 + $1.centijin } }
    private var totalAmountCent: Int { items.reduce(0) { $0 + $1.amountCent } }

    private var currentCategoryLabel: String {
        guard let id = selectedID, let cat = categories.first(where: { $0.id == id }) else { return "选择品类" }
        return "\(cat.name) · \(cat.storage.label)"
    }

    var body: some View {
        Group {
            if embedded {
                page
            } else {
                NavigationStack {
                    page
                        .navigationTitle("出库")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    // MARK: - 页面

    private var page: some View {
        List {
            Section {
                pickCard
                    .cardRow(top: 8, bottom: 8)
            }

            Section {
                if items.isEmpty {
                    EmptyHint(title: "本单还没有品类", detail: "上面选品类、填重量和售价，加入本单")
                        .cardRow(top: 18, bottom: 18)
                }
                ForEach(items) { item in
                    itemRow(item)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                remove(item)
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                        .flatRow()
                }
                if !items.isEmpty {
                    totalCard
                        .cardRow(top: 6, bottom: 6)
                }
            } header: {
                sectionHeader
            }

            Section {
                submitCard
                    .cardRow(top: 8, bottom: 24)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        .scrollDismissesKeyboard(.interactively)
        .toastOverlay()
        .sheet(isPresented: $showCustomerHistory) {
            PartyHistorySheet(title: "历史客户",
                              names: SQLiteStore.shared.partyNames("customer")) { picked in
                customer = picked
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focus = nil }
            }
        }
        .onAppear { loadCategories() }
        .sheet(isPresented: $showResult) {
            if let result {
                OutboundResultSheet(result: result) {
                    showResult = false
                    loadCategories()
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: Theme.s2) {
            Text("本单")
                .font(Theme.label())
                .tracking(1.5)
                .foregroundStyle(Theme.ink3)
            Spacer()
            Text("\(items.count) 项 · \(Units.formatJin(totalCentijin)) 斤")
                .font(Theme.label())
                .foregroundStyle(Theme.ink3)
        }
        .textCase(nil)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, 6)
        .background(Theme.paper)
    }

    // MARK: - 选择卡片

    private var pickCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                CardTitle("加入本单")

                Menu {
                    ForEach(categories) { cat in
                        Button {
                            selectedID = cat.id
                        } label: {
                            Text("\(cat.name) · \(cat.storage.label)")
                        }
                    }
                } label: {
                    HStack(spacing: Theme.s2) {
                        Text(currentCategoryLabel)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                    .inkField()
                }

                if let stock = currentStockCentijin {
                    HStack(spacing: Theme.s2) {
                        Text("在库 " + Units.formatJin(stock) + " 斤")
                            .font(Theme.number(13))
                            .foregroundStyle(isOverStock ? Theme.signal : Theme.ink2)
                        if let count = batchCountByID[selectedID ?? ""], count > 0 {
                            Text("· " + String(count) + " 批")
                                .font(.caption)
                                .foregroundStyle(Theme.ink3)
                        }
                        if isOverStock {
                            Text("超出库存")
                                .font(.caption)
                                .foregroundStyle(Theme.signal)
                        }
                        Spacer()
                    }
                }

                HStack(alignment: .top, spacing: Theme.s3) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("重量")
                            .font(Theme.label())
                            .foregroundStyle(Theme.ink3)
                        TextField(unit.prompt, text: $weightText)
                            .keyboardType(.decimalPad)
                            .focused($focus, equals: .weight)
                            .inkField()
                            .font(Theme.number(20))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("单位")
                            .font(Theme.label())
                            .foregroundStyle(Theme.ink3)
                        Picker("单位", selection: $unit) {
                            ForEach(WeightUnit.allCases) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 108)
                    }
                }

                LabeledField("售价（元/斤）") {
                    TextField("0.00", text: $priceText)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .price)
                        .inkField()
                }

                HStack(alignment: .firstTextBaseline, spacing: Theme.s2) {
                    Text(convertedHint)
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: Theme.s2)
                    Text("金额 \(amountText)")
                        .font(Theme.number(13))
                        .foregroundStyle(Theme.ink2)
                }

                Button {
                    addItem()
                } label: {
                    Label("加入本单", systemImage: "plus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var currentStockCentijin: Int? {
        guard let id = selectedID else { return nil }
        return stockByID[id] ?? 0
    }

    private var isOverStock: Bool {
        guard let stock = currentStockCentijin,
              let centijin = unit.centijin(from: weightText) else { return false }
        return centijin > stock
    }

    private var convertedHint: String {
        guard let centijin = unit.centijin(from: weightText) else {
            let stock = currentStockCentijin.map { Units.formatJin($0) } ?? "—"
            return "1 公斤 = 2 斤 · 在库 " + stock + " 斤"
        }
        let base = unit.hint(centijin)
        if let stock = currentStockCentijin {
            return base + " · 在库 " + Units.formatJin(stock) + " 斤"
        }
        return base
    }

    private var amountText: String {
        guard let centijin = unit.centijin(from: weightText) else { return "—" }
        let priceCent = parsePriceCent()
        guard priceCent > 0 else { return "—" }
        return Units.formatYuan(centijin * priceCent / 100)
    }

    private func parsePriceCent() -> Int {
        let cleaned = priceText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value >= 0 else { return 0 }
        return Units.cent(fromYuan: value)
    }

    // MARK: - 本单行

    private func itemRow(_ item: PendingItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.categoryName)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                Text("\(Units.formatYuan(item.unitPriceCent))/斤")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: Theme.s2)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(Units.formatJin(item.centijin)) 斤")
                    .font(Theme.number(16))
                    .foregroundStyle(Theme.ink)
                Text(Units.formatYuan(item.amountCent))
                    .font(Theme.number(12, weight: .regular))
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private var totalCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.s3) {
            Text("本单合计")
                .font(Theme.label())
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: Theme.s2)
            Text("\(Units.formatJin(totalCentijin)) 斤")
                .font(Theme.number(16))
                .foregroundStyle(Theme.ink)
            Text(Units.formatYuan(totalAmountCent))
                .font(Theme.number(16))
                .foregroundStyle(Theme.signal)
        }
    }

    // MARK: - 提交卡片

    private var submitCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                CardTitle("客户")
                HStack(spacing: Theme.s2) {
                    TextField("例如：北海海鲜楼", text: $customer)
                        .focused($focus, equals: .customer)
                        .inkField()
                    Button {
                        showCustomerHistory = true
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
                    .accessibilityLabel("选择历史客户")
                }

                if let errorText {
                    ErrorLine(text: errorText)
                }

                Button {
                    submit()
                } label: {
                    Text(submitting ? "提交中…" : "提交出库")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(submitting || items.isEmpty)

                HStack(spacing: Theme.s2) {
                    Text(items.isEmpty ? "先加入至少一个品类" : "共 \(items.count) 个品类 · \(Units.formatJin(totalCentijin)) 斤")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: Theme.s2)
                    Button("清空") { clearAll() }
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                        .disabled(items.isEmpty)
                }
            }
        }
    }

    // MARK: - 动作

    private func loadCategories() {
        categories = SQLiteStore.shared.categories()
        let stock = SQLiteStore.shared.stock()
        stockByID = Dictionary(uniqueKeysWithValues: stock.map { ($0.id, $0.qtyCentijin) })
        batchCountByID = Dictionary(uniqueKeysWithValues: stock.map { ($0.id, $0.batchCount) })
        if selectedID == nil, let first = categories.first {
            selectedID = first.id
        }
        if let id = selectedID, !categories.contains(where: { $0.id == id }) {
            selectedID = categories.first?.id
        }
    }

    private func addItem() {
        errorText = nil
        focus = nil
        guard let id = selectedID, let cat = categories.first(where: { $0.id == id }) else {
            setError("请选择品类")
            return
        }
        guard let centijin = unit.centijin(from: weightText) else {
            setError("请输入有效重量（大于 0）")
            return
        }
        let priceCent = parsePriceCent()
        guard priceCent > 0 else {
            setError("请输入售价（元/斤）")
            return
        }
        let already = items.filter { $0.categoryID == id }.reduce(0) { $0 + $1.centijin }
        let stock = stockByID[id] ?? 0
        if !cat.allowNegative && centijin + already > stock {
            let left = max(0, stock - already)
            var message = "超出库存：在库 " + Units.formatJin(stock) + " 斤"
            if already > 0 {
                message += "，本单已加 " + Units.formatJin(already) + " 斤，还可出 " + Units.formatJin(left) + " 斤"
            } else {
                message += "，最多出 " + Units.formatJin(left) + " 斤"
            }
            setError(message)
            return
        }
        let item = PendingItem(categoryID: id, categoryName: cat.name, centijin: centijin, unitPriceCent: priceCent)
        withAnimation(.easeOut(duration: 0.18)) {
            items.append(item)
        }
        weightText = ""
        Haptic.success()
    }

    private func remove(_ item: PendingItem) {
        withAnimation(.easeOut(duration: 0.18)) {
            items.removeAll { $0.id == item.id }
        }
        Haptic.tap()
    }

    private func clearAll() {
        withAnimation(.easeOut(duration: 0.18)) {
            items.removeAll()
        }
        customer = ""
        weightText = ""
        priceText = ""
        errorText = nil
        result = nil
    }

    private func submit() {
        errorText = nil
        focus = nil
        guard !items.isEmpty else {
            setError("本单还没有品类")
            return
        }
        let inputs = items.map {
            OutItemInput(categoryID: $0.categoryID, centijin: $0.centijin, unitPriceCent: $0.unitPriceCent)
        }
        submitting = true
        do {
            let res = try SQLiteStore.shared.outbound(
                customer: customer.trimmingCharacters(in: .whitespacesAndNewlines),
                items: inputs
            )
            result = res
            withAnimation(.easeOut(duration: 0.18)) {
                items.removeAll()
            }
            customer = ""
            weightText = ""
            priceText = ""
            Haptic.success()
            SQLiteStore.shared.addPartyName("customer", customer)
            ToastCenter.shared.show("出库成功 · " + res.docNo, kind: .success)
            showResult = true
            Task { await LowStockNotifier.shared.check() }
            if appMode == "remote" {
                Task { @MainActor in
                    SyncEngine.shared.autoSyncAfterWrite()
                }
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

// MARK: - 出库结果

/// 出库结果：单号、总额、每个品类的扣减批次。
private struct OutboundResultSheet: View {
    let result: OutboundResult
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.s3) {
                    Card {
                        VStack(alignment: .leading, spacing: Theme.s2) {
                            HStack {
                                CardTitle("出库成功")
                                Spacer(minLength: Theme.s2)
                                StampView(text: "已出账", color: Theme.signal)
                            }
                            KVLine(title: "单号", value: result.docNo)
                            KVLine(title: "总额", value: Units.formatYuan(result.totalCent), valueColor: Theme.signal)
                        }
                    }

                    ForEach(result.items.indices, id: \.self) { index in
                        let item = result.items[index]
                        Card {
                            VStack(alignment: .leading, spacing: Theme.s2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.categoryName)
                                        .font(.body)
                                        .foregroundStyle(Theme.ink)
                                    Spacer(minLength: Theme.s2)
                                    Text("\(Units.formatJin(item.centijin)) 斤")
                                        .font(Theme.number(16))
                                        .foregroundStyle(Theme.ink)
                                }
                                ForEach(item.allocations.indices, id: \.self) { index in
                                    let alloc = item.allocations[index]
                                    HStack(spacing: Theme.s2) {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.ink3)
                                        Text(alloc.batchNo)
                                            .font(Theme.number(11, weight: .regular))
                                            .foregroundStyle(Theme.ink3)
                                        Spacer(minLength: Theme.s2)
                                        Text("\(Units.formatJin(alloc.centijin)) 斤")
                                            .font(Theme.number(12, weight: .regular))
                                            .foregroundStyle(Theme.ink2)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.s4)
                .padding(.bottom, Theme.s5)
            }
            .background(PaperBackground())
            .navigationTitle("出库完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onClose() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
