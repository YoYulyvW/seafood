import Foundation

// MARK: - 存储方式

enum StorageKind: String, Codable, CaseIterable, Identifiable {
    case chilled, frozen, live
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chilled: return "冰鲜"
        case .frozen: return "冷冻"
        case .live: return "活鲜"
        }
    }
    var symbol: String {
        switch self {
        case .chilled: return "snowflake"
        case .frozen: return "thermometer.snowflake"
        case .live: return "drop.fill"
        }
    }
}

// MARK: - 品类

struct Category: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var storage: StorageKind
    var warnCentijin: Int
    var allowNegative: Bool
    var sort: Int
    var active: Bool
    var createdAt: Int64      // epoch millis
    var updatedAt: Int64
    var deleted: Bool

    var warnJin: Double {
        get { Double(warnCentijin) / 100 }
        set { warnCentijin = Int((newValue * 100).rounded()) }
    }
}

// MARK: - 批次

struct Batch: Identifiable, Codable, Equatable {
    var id: String
    var categoryID: String
    var batchNo: String
    var supplier: String
    var origin: String
    var receivedAt: Int64
    var qtyInCentijin: Int
    var qtyLeftCentijin: Int
    var unitCostCent: Int
    var note: String
    var updatedAt: Int64
    var deleted: Bool

    var leftJin: Double { Double(qtyLeftCentijin) / 100 }
}

// MARK: - 流水

enum MovementKind: String, Codable, CaseIterable {
    case inbound = "in"
    case out, loss, count
    var label: String {
        switch self {
        case .inbound: return "入库"
        case .out: return "出库"
        case .loss: return "损耗"
        case .count: return "盘点"
        }
    }
    var isPositive: Bool { self == .inbound || self == .count }
}

struct Movement: Identifiable, Codable, Equatable {
    var id: String
    var ts: Int64
    var kind: MovementKind
    var categoryID: String
    var batchID: String?
    var qtyCentijin: Int        // 入正出负
    var unitPriceCent: Int
    var amountCent: Int
    var party: String
    var operatorName: String
    var docNo: String
    var note: String
    var updatedAt: Int64
    var deleted: Bool
}

// MARK: - 视图模型

struct StockRow: Identifiable, Equatable {
    var id: String { category.id }
    var category: Category
    var qtyCentijin: Int
    var avgCostCent: Int
    var batchCount: Int
    var todayDeltaCentijin: Int

    var jin: Double { Double(qtyCentijin) / 100 }
    var avgCostYuan: Double { Double(avgCostCent) / 100 }
    var todayDeltaJin: Double { Double(todayDeltaCentijin) / 100 }
    var isLow: Bool { category.warnCentijin > 0 && qtyCentijin < category.warnCentijin }
}

struct DaySummary: Equatable {
    var date: Date
    var totalCentijin: Int
    var categoryCount: Int
    var batchCount: Int
    var inCentijin: Int
    var outCentijin: Int
    var inAmountCent: Int
    var outAmountCent: Int
    var lowStocks: [StockRow]
    var recent: [Movement]

    var totalJin: Double { Double(totalCentijin) / 100 }
    var inJin: Double { Double(inCentijin) / 100 }
    var outJin: Double { Double(outCentijin) / 100 }
}

struct InboundResult {
    var batchNo: String
    var docNo: String
    var centijin: Int
    var amountCent: Int
}

struct OutItemInput {
    var categoryID: String
    var centijin: Int
    var unitPriceCent: Int
    var preferredBatchID: String? = nil
}

struct OutAllocation {
    var batchNo: String
    var centijin: Int
}

struct OutItemResult {
    var categoryName: String
    var centijin: Int
    var allocations: [OutAllocation]
}

struct OutboundResult {
    var docNo: String
    var totalCent: Int
    var items: [OutItemResult]
}

struct CountResult {
    var diffCentijin: Int
    var docNo: String
    var bookCentijin: Int
    var actualCentijin: Int
}

// MARK: - 错误

enum InventoryError: LocalizedError {
    case message(String)
    case stockShort(name: String, need: Int, have: Int)

    var errorDescription: String? {
        switch self {
        case .message(let text):
            return text
        case .stockShort(let name, let need, let have):
            return String(format: "%@不足：需 %@ 斤，剩 %@ 斤", name, Self.jin(need), Self.jin(have))
        }
    }

    private static func jin(_ centijin: Int) -> String {
        let v = Double(centijin) / 100
        if v == v.rounded() { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}

// MARK: - 工具

enum Units {
    static func centijin(fromJin jin: Double) -> Int { Int((jin * 100).rounded()) }
    static func jin(fromCentijin c: Int) -> Double { Double(c) / 100 }
    static func cent(fromYuan yuan: Double) -> Int { Int((yuan * 100).rounded()) }
    static func yuan(fromCent c: Int) -> Double { Double(c) / 100 }

    /// 支持 12.5 / 12.5斤 / 6.25kg / 6.25公斤
    static func parseJin(_ raw: String, unit: String = "jin") -> Double? {
        let text = raw
            .replacingOccurrences(of: "公斤", with: "")
            .replacingOccurrences(of: "千克", with: "")
            .replacingOccurrences(of: "kg", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "斤", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let value = Double(text), value > 0 else { return nil }
        let isKg = raw.contains("kg") || raw.localizedCaseInsensitiveContains("kg")
            || raw.contains("公斤") || raw.contains("千克")
            || unit == "kg"
        return isKg ? value * 2 : value
    }

    static func formatJin(_ centijin: Int) -> String {
        let v = Double(centijin) / 100
        if v == v.rounded() { return String(format: "%.0f", v) }
        if (v * 10).rounded() == v * 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }

    static func formatYuan(_ cent: Int) -> String {
        let v = Double(cent) / 100
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "¥" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
    }

    static func formatJinUnit(_ centijin: Int) -> String {
        formatJin(centijin) + " 斤"
    }
}

enum Fmt {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func dayString(_ date: Date) -> String { day.string(from: date) }

    static func timeString(_ millis: Int64) -> String {
        time.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func dayTimeString(_ millis: Int64) -> String {
        dayTime.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func millis(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
}
