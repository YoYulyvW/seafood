import SwiftUI

/// 流水页：日期区间 + 类型/品类筛选，按天分组的出入库明细。
struct FlowView: View {
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Calendar.current.startOfDay(for: Date())
    @State private var kindTag = "all"
    @State private var categoryID: String?
    @State private var categories: [Category] = []
    @State private var rows: [Movement] = []

    /// 一天一组。
    struct FlowGroup: Identifiable {
        var id: String { day }
        let day: String
        let items: [Movement]
    }

    private var kind: MovementKind? { MovementKind(rawValue: kindTag) }

    private var nameMap: [String: String] {
        var map: [String: String] = [:]
        for cat in categories { map[cat.id] = cat.name }
        return map
    }

    private func categoryName(_ id: String) -> String {
        nameMap[id] ?? "未知品类"
    }

    private var inCentijin: Int {
        rows.filter { $0.kind == .in }.reduce(0) { $0 + $1.qtyCentijin }
    }

    private var outCentijin: Int {
        -rows.filter { $0.kind == .out }.reduce(0) { $0 + $1.qtyCentijin }
    }

    private var inAmountCent: Int {
        rows.filter { $0.kind == .in }.reduce(0) { $0 + $1.amountCent }
    }

    private var outAmountCent: Int {
        rows.filter { $0.kind == .out }.reduce(0) { $0 + $1.amountCent }
    }

    private var groups: [FlowGroup] {
        var order: [String] = []
        var bucket: [String: [Movement]] = [:]
        for item in rows {
            let day = Fmt.dayString(Date(timeIntervalSince1970: Double(item.ts) / 1000))
            if bucket[day] == nil {
                order.append(day)
                bucket[day] = []
            }
            bucket[day]?.append(item)
        }
        return order.map { FlowGroup(day: $0, items: bucket[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    filterCard
                        .cardRow(top: 8, bottom: 8)
                }

                if groups.isEmpty {
                    Section {
                        EmptyHint(title: "这段时间没有流水", detail: "换个日期区间或清掉筛选条件")
                            .cardRow(top: 28, bottom: 28)
                    }
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                row(item)
                                    .flatRow()
                            }
                        } header: {
                            dayHeader(group)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(PaperBackground())
            .navigationTitle("流水")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                load()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            .onAppear { load() }
            .onChange(of: from) { value in
                if value > to { to = value }
                load()
            }
            .onChange(of: to) { _ in load() }
            .onChange(of: kindTag) { _ in load() }
            .onChange(of: categoryID) { _ in load() }
        }
    }

    // MARK: - 顶部筛选

    private var filterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.s3) {
                HStack(spacing: Theme.s3) {
                    DeltaBlock(title: "入", value: "+" + Units.formatJin(inCentijin), color: Theme.jade)
                    DeltaBlock(title: "出", value: "−" + Units.formatJin(outCentijin), color: Theme.signal)
                    Spacer(minLength: 0)
                }
                HStack(spacing: Theme.s2) {
                    Text("金额")
                        .font(Theme.label())
                        .foregroundStyle(Theme.ink3)
                    Text("\(Units.formatYuan(inAmountCent)) / \(Units.formatYuan(outAmountCent))")
                        .font(Theme.number(12, weight: .regular))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 0)
                    Text("\(rows.count) 条")
                        .font(Theme.label())
                        .foregroundStyle(Theme.ink3)
                }

                RuleDivider()

                HStack(spacing: Theme.s3) {
                    DatePicker("从", selection: $from, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    DatePicker("到", selection: $to, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }
                .font(.subheadline)

                Picker("类型", selection: $kindTag) {
                    Text("全部").tag("all")
                    ForEach(MovementKind.allCases, id: \.rawValue) { item in
                        Text(item.label).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Menu {
                    Button {
                        categoryID = nil
                    } label: {
                        Text("全部品类")
                    }
                    Divider()
                    ForEach(categories) { cat in
                        Button {
                            categoryID = cat.id
                        } label: {
                            Text(cat.name)
                        }
                    }
                } label: {
                    HStack(spacing: Theme.s2) {
                        Text(categoryID.flatMap { nameMap[$0] } ?? "全部品类")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                    .inkField()
                }
            }
        }
    }

    // MARK: - 分组头

    private func dayHeader(_ group: FlowGroup) -> some View {
        let dayIn = group.items.filter { $0.kind == .in }.reduce(0) { $0 + $1.qtyCentijin }
        let dayOut = -group.items.filter { $0.kind == .out }.reduce(0) { $0 + $1.qtyCentijin }
        return HStack(spacing: Theme.s2) {
            Text(group.day)
                .font(Theme.number(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            Text("入 " + Units.formatJin(dayIn))
                .font(Theme.number(11, weight: .regular))
                .foregroundStyle(Theme.jade)
            Text("出 " + Units.formatJin(dayOut))
                .font(Theme.number(11, weight: .regular))
                .foregroundStyle(Theme.signal)
        }
        .textCase(nil)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, 6)
        .background(Theme.paper)
    }

    // MARK: - 行

    private func row(_ item: Movement) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Theme.s2) {
                Text(Fmt.timeString(item.ts))
                    .font(Theme.number(11, weight: .regular))
                    .foregroundStyle(Theme.ink3)
                Text(categoryName(item.categoryID))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Tag(text: item.kind.label, color: kindColor(item.kind))
                Spacer(minLength: Theme.s2)
                Text(signedQty(item))
                    .font(Theme.number(15))
                    .foregroundStyle(kindColor(item.kind))
            }
            HStack(spacing: Theme.s2) {
                Text(item.docNo)
                    .font(Theme.number(10, weight: .regular))
                    .foregroundStyle(Theme.ink3)
                if !item.party.isEmpty {
                    Text(item.party)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.s2)
                Text(Units.formatYuan(item.amountCent))
                    .font(Theme.number(11, weight: .regular))
                    .foregroundStyle(Theme.ink2)
            }
        }
    }

    private func signedQty(_ item: Movement) -> String {
        let sign = item.qtyCentijin > 0 ? "+" : "−"
        return sign + Units.formatJin(abs(item.qtyCentijin)) + " 斤"
    }

    private func kindColor(_ kind: MovementKind) -> Color {
        switch kind {
        case .in: return Theme.jade
        case .out: return Theme.signal
        case .loss: return Theme.ink2
        case .count: return Theme.ice
        }
    }

    // MARK: - 数据

    private func load() {
        categories = SQLiteStore.shared.allCategories()
        rows = SQLiteStore.shared.movements(from: from, to: to, kind: kind, categoryID: categoryID, limit: 500)
    }
}
