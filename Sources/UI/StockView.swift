import SwiftUI

/// 库存首页：过磅单式大数字 + 品类行内联批次明细。
struct StockView: View {
    @State private var stocks: [StockRow] = []
    @State private var summary: DaySummary? = nil
    @State private var lastCountTs: Int64? = nil
    @State private var search = ""
    @State private var filter: StorageFilter = .all
    @State private var expandedID: String? = nil
    @State private var batchCache: [String: [Batch]] = [:]
    @State private var showInbound = false
    @State private var showOutbound = false

    /// 存储方式筛选（带"全部"）。
    enum StorageFilter: String, CaseIterable, Identifiable {
        case all
        case chilled
        case frozen
        case live

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "全部"
            case .chilled: return StorageKind.chilled.label
            case .frozen: return StorageKind.frozen.label
            case .live: return StorageKind.live.label
            }
        }

        var kind: StorageKind? {
            self == .all ? nil : StorageKind(rawValue: rawValue)
        }
    }

    private var filtered: [StockRow] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return stocks.filter { row in
            if let kind = filter.kind, row.category.storage != kind { return false }
            if !keyword.isEmpty, !row.category.name.localizedCaseInsensitiveContains(keyword) { return false }
            return true
        }
    }

    private var lowCount: Int { filtered.filter { $0.isLow }.count }
    @State private var batchCategory: Category?

    private var stampText: String {
        guard let ts = lastCountTs else { return "未盘点" }
        return "已盘 \(Fmt.timeString(ts))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    chips
                    actions
                }

                Section {
                    if filtered.isEmpty {
                        EmptyHint(title: "没有匹配的品类", detail: "换个关键词，或去入库页新建品类")
                            .cardRow(top: 24, bottom: 24)
                    }
                    ForEach(filtered) { row in
                        categoryRow(row)
                    }
                } header: {
                    HStack(spacing: Theme.s2) {
                        Text("品类")
                            .font(Theme.label())
                            .tracking(1.5)
                            .foregroundStyle(Theme.ink3)
                        Spacer()
                        Text(lowCount > 0 ? "\(filtered.count) 项 · \(lowCount) 个低库存" : "\(filtered.count) 项")
                            .font(Theme.label())
                            .foregroundStyle(Theme.ink3)
                    }
                    .textCase(nil)
                    .padding(.horizontal, Theme.s4)
                    .padding(.vertical, 6)
                    .background(Theme.paper)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .navigationTitle("库存")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索品类")
            .refreshable {
                await MainActor.run { reload() }
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            .onAppear { reload() }
            .sheet(item: $batchCategory) { category in
                NavigationStack {
                    BatchListView(category: category)
                }
            }
            .sheet(isPresented: $showInbound) {
                NavigationStack {
                    InboundView(embedded: true)
                        .navigationTitle("入库")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showInbound = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showOutbound) {
                NavigationStack {
                    OutboundView(embedded: true)
                        .navigationTitle("出库")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showOutbound = false }
                            }
                        }
                }
            }
            .onChange(of: showInbound) { opened in
                if !opened { reload() }
            }
            .onChange(of: showOutbound) { opened in
                if !opened { reload() }
            }
        }
    }

    // MARK: - 顶部过磅单

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(alignment: .top, spacing: Theme.s3) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("过 磅 单")
                            .font(Theme.label())
                            .tracking(3)
                            .foregroundStyle(Theme.ink3)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(Units.formatJin(summary?.totalCentijin ?? 0))
                                .font(Theme.number(56))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                            Text("斤")
                                .font(Theme.number(18, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                        }
                        Text("\(summary?.categoryCount ?? 0) 品类 · \(summary?.batchCount ?? 0) 批次")
                            .font(.caption)
                            .foregroundStyle(Theme.ink3)
                    }
                    Spacer(minLength: Theme.s2)
                    StampView(text: stampText, color: lastCountTs == nil ? Theme.ink3 : Theme.signal)
                        .padding(.top, 4)
                }

                DottedRule()

                HStack(alignment: .top, spacing: Theme.s5) {
                    DeltaBlock(title: "今日入",
                               value: "+" + Units.formatJin(summary?.inCentijin ?? 0),
                               color: Theme.jade)
                    DeltaBlock(title: "今日出",
                               value: "−" + Units.formatJin(summary?.outCentijin ?? 0),
                               color: Theme.signal)
                    Spacer(minLength: 0)
                }
            }
        }
        .cardRow(top: 8, bottom: 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.s2) {
                ForEach(StorageFilter.allCases) { item in
                    FilterChip(title: item.label, isOn: filter == item) {
                        Haptic.tap()
                        withAnimation(.easeOut(duration: 0.16)) { filter = item }
                    }
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 1)
        }
        .cardRow(top: 2, bottom: 2)
    }

    private var actions: some View {
        HStack(spacing: Theme.s3) {
            Button {
                Haptic.tap()
                showInbound = true
            } label: {
                Label("入库", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                Haptic.tap()
                showOutbound = true
            } label: {
                Label("出库", systemImage: "tray.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .cardRow(top: 6, bottom: 10)
    }

    // MARK: - 品类行

    private func categoryRow(_ row: StockRow) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.s3) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(row.category.name)
                            .font(.body)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        StorageTag(storage: row.category.storage)
                        if row.isLow {
                            Tag(text: "低库存", color: Theme.signal)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("均价 \(Units.formatYuan(row.avgCostCent))")
                        Text(deltaText(row))
                            .foregroundStyle(deltaColor(row))
                        Text("\(row.batchCount) 批")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                }

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Units.formatJin(row.qtyCentijin))
                        .font(Theme.number(26))
                        .foregroundStyle(Theme.ink)
                    Text("斤")
                        .font(Theme.label())
                        .foregroundStyle(Theme.ink3)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .rotationEffect(.degrees(expandedID == row.id ? 90 : 0))
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    batchCategory = row.category
                    Haptic.tap()
                }
            )
            .onTapGesture { toggle(row) }

            if expandedID == row.id {
                batchDetail(row)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .flatRow()
    }

    private func batchDetail(_ row: StockRow) -> some View {
        let batches = batchCache[row.id] ?? []
        return VStack(spacing: 0) {
            if batches.isEmpty {
                Text("暂无剩余批次")
                    .font(.caption)
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            ForEach(batches) { batch in
                HStack(spacing: 8) {
                    Text(batch.batchNo)
                        .font(Theme.number(10, weight: .regular))
                        .foregroundStyle(Theme.ink3)
                    Text(batch.supplier.isEmpty ? "—" : batch.supplier)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(Units.formatJin(batch.qtyLeftCentijin)) 斤")
                        .font(Theme.number(12))
                        .foregroundStyle(Theme.ink)
                    Text(Units.formatYuan(batch.unitCostCent) + "/斤")
                        .font(.caption2)
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.vertical, 7)
                if batch.id != batches.last?.id {
                    RuleDivider()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(Theme.paper.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func deltaText(_ row: StockRow) -> String {
        let delta = row.todayDeltaCentijin
        if delta == 0 { return "今日持平" }
        return delta > 0 ? "今日 +\(Units.formatJin(delta)) 斤" : "今日 −\(Units.formatJin(-delta)) 斤"
    }

    private func deltaColor(_ row: StockRow) -> Color {
        if row.todayDeltaCentijin == 0 { return Theme.ink3 }
        return row.todayDeltaCentijin > 0 ? Theme.jade : Theme.signal
    }

    // MARK: - 数据

    private func reload() {
        StockAlertCenter.shared.refresh(playSound: false)
        let store = SQLiteStore.shared
        summary = store.summary()
        stocks = store.stock()
        lastCountTs = store.movements(from: Date(), to: Date(), kind: .count, categoryID: nil, limit: 1).first?.ts
        if let id = expandedID {
            batchCache[id] = store.batches(categoryID: id)
        }
    }

    private func toggle(_ row: StockRow) {
        Haptic.tap()
        if expandedID != row.id {
            batchCache[row.id] = SQLiteStore.shared.batches(categoryID: row.id)
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            expandedID = expandedID == row.id ? nil : row.id
        }
    }
}
