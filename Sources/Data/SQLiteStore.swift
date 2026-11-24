import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 本地 SQLite：单一真相是流水（movement），批次只记剩余量。
/// 所有写操作都会把 updatedAt 抬到当前毫秒，供远程同步做 LWW 合并。
final class SQLiteStore {
    static let shared = SQLiteStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.yoyulyvw.seafood.db")

    // MARK: - 生命周期

    init(path: String? = nil) {
        let fileURL = path.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL()
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            assertionFailure("无法打开数据库：\(fileURL.path)")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA busy_timeout=5000;")
        exec("PRAGMA foreign_keys=ON;")
        migrate()
    }

    static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("seafood.db")
    }

    deinit { sqlite3_close(db) }

    // MARK: - 基础

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func errText() -> String {
        guard let db, let c = sqlite3_errmsg(db) else { return "未知数据库错误" }
        return String(cString: c)
    }

    private enum Value {
        case text(String)
        case int(Int64)
        case intOrNull(Int64?)
        case double(Double)
        case null
    }

    private func prepare(_ sql: String, _ values: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, n)
            case .intOrNull(let n):
                if let n { sqlite3_bind_int64(stmt, idx, n) } else { sqlite3_bind_null(stmt, idx) }
            case .double(let d):
                sqlite3_bind_double(stmt, idx, d)
            case .null:
                sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ values: [Value] = []) throws {
        guard let stmt = prepare(sql, values) else { throw InventoryError.message(errText()) }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw InventoryError.message(errText()) }
    }

    private func rows(_ sql: String, _ values: [Value], each: (OpaquePointer) -> Void) {
        guard let stmt = prepare(sql, values) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private func text(_ stmt: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    private func optText(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
        return text(stmt, i)
    }

    private func int(_ stmt: OpaquePointer, _ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

    // MARK: - Schema

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS category (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            storage TEXT NOT NULL,
            warn_centijin INTEGER NOT NULL DEFAULT 0,
            allow_negative INTEGER NOT NULL DEFAULT 0,
            sort INTEGER NOT NULL DEFAULT 100,
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS batch (
            id TEXT PRIMARY KEY,
            category_id TEXT NOT NULL,
            batch_no TEXT NOT NULL,
            supplier TEXT NOT NULL DEFAULT '',
            origin TEXT NOT NULL DEFAULT '',
            received_at INTEGER NOT NULL,
            qty_in_centijin INTEGER NOT NULL,
            qty_left_centijin INTEGER NOT NULL,
            unit_cost_cent INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_batch_cat ON batch(category_id, received_at);
        CREATE TABLE IF NOT EXISTS movement (
            id TEXT PRIMARY KEY,
            ts INTEGER NOT NULL,
            kind TEXT NOT NULL,
            category_id TEXT NOT NULL,
            batch_id TEXT,
            qty_centijin INTEGER NOT NULL,
            unit_price_cent INTEGER NOT NULL DEFAULT 0,
            amount_cent INTEGER NOT NULL DEFAULT 0,
            party TEXT NOT NULL DEFAULT '',
            operator TEXT NOT NULL DEFAULT '',
            doc_no TEXT NOT NULL DEFAULT '',
            note TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_mov_ts ON movement(ts);
        CREATE INDEX IF NOT EXISTS idx_mov_cat ON movement(category_id, ts);
        CREATE TABLE IF NOT EXISTS demo_mark (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            PRIMARY KEY(kind, id)
        );
        CREATE TABLE IF NOT EXISTS party_history (
            kind TEXT NOT NULL,
            name TEXT NOT NULL,
            used_at INTEGER NOT NULL,
            PRIMARY KEY(kind, name)
        );
        CREATE TABLE IF NOT EXISTS audit_log (
            id TEXT PRIMARY KEY,
            ts INTEGER NOT NULL,
            operator TEXT NOT NULL DEFAULT '',
            action TEXT NOT NULL,
            target TEXT NOT NULL,
            detail TEXT NOT NULL,
            updated_at INTEGER NOT NULL DEFAULT 0,
            batch_id TEXT NOT NULL DEFAULT '',
            before_text TEXT NOT NULL DEFAULT '',
            after_text TEXT NOT NULL DEFAULT '',
            reason TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS setting (k TEXT PRIMARY KEY, v TEXT NOT NULL);
        INSERT OR IGNORE INTO setting(k, v) VALUES ('sync_last_at', '0');
        INSERT OR IGNORE INTO setting(k, v) VALUES ('operator', '');
        INSERT OR IGNORE INTO setting(k, v) VALUES ('seeded', '0');
        INSERT OR IGNORE INTO setting(k, v) VALUES ('init_done', '0');
        INSERT OR IGNORE INTO setting(k, v) VALUES ('mysql_dsn', '');
        INSERT OR IGNORE INTO setting(k, v) VALUES ('update_url', '');
        """)
        // 老库补列：逐条探测，避免一条失败把后面全吞掉
        ensureColumn("audit_log", "updated_at", "INTEGER NOT NULL DEFAULT 0")
        ensureColumn("audit_log", "batch_id", "TEXT NOT NULL DEFAULT ''")
        ensureColumn("audit_log", "before_text", "TEXT NOT NULL DEFAULT ''")
        ensureColumn("audit_log", "after_text", "TEXT NOT NULL DEFAULT ''")
        ensureColumn("audit_log", "reason", "TEXT NOT NULL DEFAULT ''")
    }

    // MARK: - 迁移工具

    private func columnNames(_ table: String) -> Set<String> {
        var names: Set<String> = []
        rows("PRAGMA table_info(" + table + ")", []) { names.insert(text($0, 1)) }
        return names
    }

    /// 幂等补列：先查 table_info，缺了才 ALTER 一次。
    private func ensureColumn(_ table: String, _ column: String, _ definition: String) {
        guard !columnNames(table).contains(column) else { return }
        exec("ALTER TABLE " + table + " ADD COLUMN " + column + " " + definition)
    }

    // MARK: - 设置项

    func setting(_ key: String) -> String {
        var value = ""
        rows("SELECT v FROM setting WHERE k = ?", [.text(key)]) { value = text($0, 0) }
        return value
    }

    func setSetting(_ key: String, _ value: String) {
        try? run("INSERT INTO setting(k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
                 [.text(key), .text(value)])
    }

    func lastSyncAt() -> Int64 { Int64(setting("sync_last_at")) ?? 0 }

    func setLastSyncAt(_ value: Int64) { setSetting("sync_last_at", String(value)) }

    // MARK: - 读：品类

    func categories(includeInactive: Bool = false) -> [Category] {
        var out: [Category] = []
        let sql = "SELECT * FROM category WHERE deleted = 0 "
            + (includeInactive ? "" : "AND active = 1 ")
            + "ORDER BY sort, name"
        rows(sql, []) { st in
            out.append(Category(
                id: text(st, 0),
                name: text(st, 1),
                storage: StorageKind(rawValue: text(st, 2)) ?? .chilled,
                warnCentijin: Int(int(st, 3)),
                allowNegative: int(st, 4) == 1,
                sort: Int(int(st, 5)),
                active: int(st, 6) == 1,
                createdAt: int(st, 7),
                updatedAt: int(st, 8),
                deleted: int(st, 9) == 1
            ))
        }
        return out
    }

    func category(id: String) -> Category? {
        categories(includeInactive: true).first { $0.id == id }
    }

    // MARK: - 读：库存

    func stock() -> [StockRow] {
        let cats = categories()
        var result: [StockRow] = []
        let dayStart = Calendar.current.startOfDay(for: Date())
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let startMs = Fmt.millis(dayStart)
        let endMs = Fmt.millis(dayEnd)

        for cat in cats {
            var qty = 0
            var costSum: Int64 = 0
            var batchCount = 0
            rows("SELECT qty_left_centijin, unit_cost_cent FROM batch WHERE category_id = ? AND qty_left_centijin > 0 AND deleted = 0",
                 [.text(cat.id)]) { st in
                let left = Int(int(st, 0))
                qty += left
                costSum += Int64(left) * int(st, 1)
                batchCount += 1
            }
            var delta = 0
            rows("SELECT COALESCE(SUM(qty_centijin), 0) FROM movement WHERE category_id = ? AND deleted = 0 AND ts >= ? AND ts < ?",
                 [.text(cat.id), .int(startMs), .int(endMs)]) { delta = Int(int($0, 0)) }
            let avg = qty > 0 ? Int(costSum / Int64(qty)) : 0
            result.append(StockRow(category: cat, qtyCentijin: qty, avgCostCent: avg,
                                   batchCount: batchCount, todayDeltaCentijin: delta))
        }
        return result
    }

    func batches(categoryID: String) -> [Batch] {
        var out: [Batch] = []
        rows("SELECT * FROM batch WHERE category_id = ? AND qty_left_centijin > 0 AND deleted = 0 ORDER BY received_at",
             [.text(categoryID)]) { st in
            out.append(readBatch(st))
        }
        return out
    }

    private func readBatch(_ st: OpaquePointer) -> Batch {
        Batch(id: text(st, 0), categoryID: text(st, 1), batchNo: text(st, 2),
              supplier: text(st, 3), origin: text(st, 4),
              receivedAt: int(st, 5), qtyInCentijin: Int(int(st, 6)),
              qtyLeftCentijin: Int(int(st, 7)), unitCostCent: Int(int(st, 8)),
              note: text(st, 9), updatedAt: int(st, 10), deleted: int(st, 11) == 1)
    }

    private func readMovement(_ st: OpaquePointer) -> Movement {
        Movement(id: text(st, 0), ts: int(st, 1),
                 kind: MovementKind(rawValue: text(st, 2)) ?? .inbound,
                 categoryID: text(st, 3), batchID: optText(st, 4),
                 qtyCentijin: Int(int(st, 5)), unitPriceCent: Int(int(st, 6)),
                 amountCent: Int(int(st, 7)), party: text(st, 8),
                 operatorName: text(st, 9), docNo: text(st, 10),
                 note: text(st, 11), updatedAt: int(st, 12), deleted: int(st, 13) == 1)
    }

    // MARK: - 读：首页

    func summary(on date: Date = Date()) -> DaySummary {
        let stocks = stock()
        let dayStart = Calendar.current.startOfDay(for: date)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let startMs = Fmt.millis(dayStart)
        let endMs = Fmt.millis(dayEnd)

        var inC = 0, outC = 0, inA = 0, outA = 0
        rows("SELECT kind, SUM(qty_centijin), SUM(amount_cent) FROM movement WHERE deleted = 0 AND ts >= ? AND ts < ? GROUP BY kind",
             [.int(startMs), .int(endMs)]) { st in
            let kind = text(st, 0)
            let qty = Int(int(st, 1))
            let amount = Int(int(st, 2))
            switch kind {
            case "in": inC += qty; inA += amount
            case "out": outC += -qty; outA += amount
            default: break
            }
        }
        let total = stocks.reduce(0) { $0 + $1.qtyCentijin }
        let low = stocks.filter { $0.isLow }
        return DaySummary(date: date, totalCentijin: total,
                          categoryCount: stocks.count,
                          batchCount: stocks.reduce(0) { $0 + $1.batchCount },
                          inCentijin: inC, outCentijin: outC,
                          inAmountCent: inA, outAmountCent: outA,
                          lowStocks: low,
                          recent: movements(from: nil, to: nil, kind: nil, categoryID: nil, limit: 8))
    }

    // MARK: - 读：流水

    func movements(from: Date? = nil, to: Date? = nil,
                   kind: MovementKind? = nil, categoryID: String? = nil,
                   limit: Int = 300) -> [Movement] {
        var sql = "SELECT * FROM movement WHERE deleted = 0"
        var values: [Value] = []
        if let from {
            sql += " AND ts >= ?"; values.append(.int(Fmt.millis(Calendar.current.startOfDay(for: from))))
        }
        if let to {
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
            sql += " AND ts < ?"; values.append(.int(Fmt.millis(end)))
        }
        if let kind { sql += " AND kind = ?"; values.append(.text(kind.rawValue)) }
        if let categoryID { sql += " AND category_id = ?"; values.append(.text(categoryID)) }
        sql += " ORDER BY ts DESC, rowid DESC LIMIT ?"
        values.append(.int(Int64(limit)))
        var out: [Movement] = []
        rows(sql, values) { out.append(readMovement($0)) }
        return out
    }

    // MARK: - 写：品类

    @discardableResult
    func createCategory(name: String, storage: StorageKind, warnJin: Double, allowNegative: Bool) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InventoryError.message("品类名不能为空") }
        if categories(includeInactive: true).contains(where: { $0.name == trimmed && !$0.deleted }) {
            throw InventoryError.message("品类「\(trimmed)」已存在")
        }
        let now = Fmt.millis()
        let cat = Category(id: UUID().uuidString, name: trimmed, storage: storage,
                           warnCentijin: Units.centijin(fromJin: warnJin),
                           allowNegative: allowNegative, sort: 100, active: true,
                           createdAt: now, updatedAt: now, deleted: false)
        try upsertCategory(cat)
        return cat
    }

    func upsertCategory(_ cat: Category) throws {
        try run("""
        INSERT INTO category(id, name, storage, warn_centijin, allow_negative, sort, active, created_at, updated_at, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name, storage = excluded.storage,
            warn_centijin = excluded.warn_centijin, allow_negative = excluded.allow_negative,
            sort = excluded.sort, active = excluded.active, updated_at = excluded.updated_at,
            deleted = excluded.deleted
        """, [.text(cat.id), .text(cat.name), .text(cat.storage.rawValue),
              .int(Int64(cat.warnCentijin)), .int(cat.allowNegative ? 1 : 0),
              .int(Int64(cat.sort)), .int(cat.active ? 1 : 0),
              .int(cat.createdAt), .int(cat.updatedAt), .int(cat.deleted ? 1 : 0)])
    }

    func touchCategory(_ id: String, warnJin: Double? = nil, allowNegative: Bool? = nil, active: Bool? = nil) throws {
        guard var cat = category(id: id) else { throw InventoryError.message("品类不存在") }
        if let warnJin { cat.warnCentijin = Units.centijin(fromJin: warnJin) }
        if let allowNegative { cat.allowNegative = allowNegative }
        if let active { cat.active = active }
        cat.updatedAt = Fmt.millis()
        try upsertCategory(cat)
    }

    // MARK: - 写：入库

    func inbound(categoryID: String?, newCategoryName: String?, storage: StorageKind,
                 jin: Double, unitCost: Double, supplier: String, origin: String, note: String,
                 at date: Date = Date()) throws -> InboundResult {
        let centijin = Units.centijin(fromJin: jin)
        guard centijin > 0 else { throw InventoryError.message("入库重量必须大于 0") }
        guard unitCost >= 0 else { throw InventoryError.message("单价不能为负") }

        var targetID = categoryID
        if targetID == nil {
            guard let name = newCategoryName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw InventoryError.message("请选择品类或填写新品类名")
            }
            if let existing = categories(includeInactive: true).first(where: { $0.name == name && !$0.deleted }) {
                targetID = existing.id
            } else {
                targetID = try createCategory(name: name, storage: storage, warnJin: 20, allowNegative: false).id
            }
        }
        guard let catID = targetID else { throw InventoryError.message("请选择品类") }

        let now = Fmt.millis()
        let ts = Fmt.millis(date)
        let batchID = UUID().uuidString
        let batchNo = try nextBatchNo(date: date)
        try run("BEGIN IMMEDIATE")
        do {
            try run("""
            INSERT INTO batch(id, category_id, batch_no, supplier, origin, received_at,
                              qty_in_centijin, qty_left_centijin, unit_cost_cent, note, updated_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """, [.text(batchID), .text(catID), .text(batchNo), .text(supplier), .text(origin),
                  .int(ts), .int(Int64(centijin)), .int(Int64(centijin)),
                  .int(Int64(Units.cent(fromYuan: unitCost))), .text(note), .int(now)])
            let docNo = try nextDocNo(prefix: "RK", date: date)
            let amount = centijin * Units.cent(fromYuan: unitCost) / 100
            try insertMovement(Movement(id: UUID().uuidString, ts: ts, kind: .inbound, categoryID: catID,
                                        batchID: batchID, qtyCentijin: centijin,
                                        unitPriceCent: Units.cent(fromYuan: unitCost),
                                        amountCent: amount, party: supplier,
                                        operatorName: setting("operator"), docNo: docNo,
                                        note: note, updatedAt: now, deleted: false))
            try run("COMMIT")
            return InboundResult(batchNo: batchNo, docNo: docNo, centijin: centijin, amountCent: amount)
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 写：出库（FIFO）

    func outbound(customer: String, items: [OutItemInput], at date: Date = Date()) throws -> OutboundResult {
        guard !items.isEmpty else { throw InventoryError.message("出库单为空") }
        let now = Fmt.millis()
        let ts = Fmt.millis(date)
        try run("BEGIN IMMEDIATE")
        do {
            let docNo = try nextDocNo(prefix: "CK", date: date)
            var results: [OutItemResult] = []
            var total = 0
            for item in items {
                guard item.centijin > 0 else { throw InventoryError.message("出库重量必须大于 0") }
                guard let cat = category(id: item.categoryID) else { throw InventoryError.message("品类不存在") }
                let available = batches(categoryID: cat.id)
                let have = available.reduce(0) { $0 + $1.qtyLeftCentijin }
                if have < item.centijin && !cat.allowNegative {
                    throw InventoryError.stockShort(name: cat.name, need: item.centijin, have: have)
                }
                var remain = item.centijin
                var allocs: [OutAllocation] = []
                for batch in available where remain > 0 {
                    let take = min(batch.qtyLeftCentijin, remain)
                    if take <= 0 { continue }
                    try run("UPDATE batch SET qty_left_centijin = qty_left_centijin - ?, updated_at = ? WHERE id = ?",
                            [.int(Int64(take)), .int(now), .text(batch.id)])
                    let amount = take * item.unitPriceCent / 100
                    try insertMovement(Movement(id: UUID().uuidString, ts: ts, kind: .out,
                                                categoryID: cat.id, batchID: batch.id,
                                                qtyCentijin: -take, unitPriceCent: item.unitPriceCent,
                                                amountCent: amount, party: customer,
                                                operatorName: setting("operator"), docNo: docNo,
                                                note: "", updatedAt: now, deleted: false))
                    allocs.append(OutAllocation(batchNo: batch.batchNo, centijin: take))
                    remain -= take
                    total += amount
                }
                if remain > 0 {
                    let amount = remain * item.unitPriceCent / 100
                    try insertMovement(Movement(id: UUID().uuidString, ts: ts, kind: .out,
                                                categoryID: cat.id, batchID: nil,
                                                qtyCentijin: -remain, unitPriceCent: item.unitPriceCent,
                                                amountCent: amount, party: customer,
                                                operatorName: setting("operator"), docNo: docNo,
                                                note: "负库存出库（账实待盘）", updatedAt: now, deleted: false))
                    allocs.append(OutAllocation(batchNo: "负库存", centijin: remain))
                    total += amount
                }
                results.append(OutItemResult(categoryName: cat.name, centijin: item.centijin, allocations: allocs))
            }
            try run("COMMIT")
            return OutboundResult(docNo: docNo, totalCent: total, items: results)
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 写：盘点

    func adjustCount(categoryID: String, actualJin: Double, note: String) throws -> CountResult {
        guard let cat = category(id: categoryID) else { throw InventoryError.message("品类不存在") }
        let actual = Units.centijin(fromJin: actualJin)
        guard actual >= 0 else { throw InventoryError.message("实盘数量不能为负") }
        let books = batches(categoryID: categoryID)
        let book = books.reduce(0) { $0 + $1.qtyLeftCentijin }
        let diff = actual - book
        let now = Fmt.millis()
        try run("BEGIN IMMEDIATE")
        do {
            let docNo = try nextDocNo(prefix: "PD", date: Date())
            if diff < 0 {
                var need = -diff
                for batch in books where need > 0 {
                    let take = min(batch.qtyLeftCentijin, need)
                    if take <= 0 { continue }
                    try run("UPDATE batch SET qty_left_centijin = qty_left_centijin - ?, updated_at = ? WHERE id = ?",
                            [.int(Int64(take)), .int(now), .text(batch.id)])
                    try insertMovement(Movement(id: UUID().uuidString, ts: now, kind: .loss,
                                                categoryID: categoryID, batchID: batch.id,
                                                qtyCentijin: -take, unitPriceCent: 0, amountCent: 0,
                                                party: "", operatorName: setting("operator"),
                                                docNo: docNo, note: note, updatedAt: now, deleted: false))
                    need -= take
                }
            } else if diff > 0 {
                let batchID = UUID().uuidString
                try run("""
                INSERT INTO batch(id, category_id, batch_no, supplier, origin, received_at,
                                  qty_in_centijin, qty_left_centijin, unit_cost_cent, note, updated_at, deleted)
                VALUES (?, ?, ?, '', '', ?, ?, ?, 0, '盘盈', ?, 0)
                """, [.text(batchID), .text(categoryID), .text(try nextBatchNo(date: Date())),
                      .int(now), .int(Int64(diff)), .int(Int64(diff)), .int(now)])
                try insertMovement(Movement(id: UUID().uuidString, ts: now, kind: .count,
                                            categoryID: categoryID, batchID: batchID,
                                            qtyCentijin: diff, unitPriceCent: 0, amountCent: 0,
                                            party: "", operatorName: setting("operator"),
                                            docNo: docNo, note: note, updatedAt: now, deleted: false))
            }
            try run("COMMIT")
            return CountResult(diffCentijin: diff, docNo: docNo, bookCentijin: book, actualCentijin: actual)
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 编号

    private func nextDocNo(prefix: String, date: Date) throws -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let day = df.string(from: date)
        var count = 0
        let like = "\(prefix)-\(day)-%"
        rows("SELECT COUNT(*) FROM movement WHERE doc_no LIKE ?", [.text(like)]) { count = Int(int($0, 0)) }
        return String(format: "%@-%@-%02d", prefix, day, count + 1)
    }

    private func nextBatchNo(date: Date) throws -> String {
        let df = DateFormatter()
        df.dateFormat = "MMdd"
        let day = df.string(from: date)
        var count = 0
        rows("SELECT COUNT(*) FROM batch WHERE batch_no LIKE ?", [.text("B-\(day)-%")]) { count = Int(int($0, 0)) }
        return String(format: "B-%@-%02d", day, count + 1)
    }

    private func insertMovement(_ m: Movement) throws {
        try run("""
        INSERT INTO movement(id, ts, kind, category_id, batch_id, qty_centijin, unit_price_cent,
                             amount_cent, party, operator, doc_no, note, updated_at, deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        """, [.text(m.id), .int(m.ts), .text(m.kind.rawValue), .text(m.categoryID),
              m.batchID.map { Value.text($0) } ?? .null, .int(Int64(m.qtyCentijin)),
              .int(Int64(m.unitPriceCent)), .int(Int64(m.amountCent)), .text(m.party),
              .text(m.operatorName), .text(m.docNo), .text(m.note), .int(m.updatedAt)])
    }

    /// 每条出库流水的进货成本（按 FIFO 扣到的那批的进价算），给流水页算毛利。
    func outCosts(movements: [Movement]) -> [String: Int] {
        let outs = movements.filter { $0.kind == .out }
        guard !outs.isEmpty else { return [:] }
        var result: [String: Int] = [:]
        var index = 0
        while index < outs.count {
            let chunk = Array(outs[index..<min(index + 200, outs.count)])
            let holders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT m.id, m.qty_centijin, COALESCE(b.unit_cost_cent, 0) "
                + "FROM movement m LEFT JOIN batch b ON b.id = m.batch_id WHERE m.id IN (" + holders + ")"
            rows(sql, chunk.map { Value.text($0.id) }) { st in
                let id = text(st, 0)
                let qty = Int(int(st, 1))
                let unit = Int(int(st, 2))
                result[id] = abs(qty) * unit / 100
            }
            index += 200
        }
        return result
    }

    // MARK: - 同步支持

    func changedCategories(since: Int64) -> [Category] {
        var out: [Category] = []
        rows("SELECT * FROM category WHERE updated_at > ? ORDER BY updated_at", [.int(since)]) { st in
            out.append(Category(id: text(st, 0), name: text(st, 1),
                                storage: StorageKind(rawValue: text(st, 2)) ?? .chilled,
                                warnCentijin: Int(int(st, 3)), allowNegative: int(st, 4) == 1,
                                sort: Int(int(st, 5)), active: int(st, 6) == 1,
                                createdAt: int(st, 7), updatedAt: int(st, 8), deleted: int(st, 9) == 1))
        }
        return out
    }

    func changedBatches(since: Int64) -> [Batch] {
        var out: [Batch] = []
        rows("SELECT * FROM batch WHERE updated_at > ? ORDER BY updated_at", [.int(since)]) { out.append(readBatch($0)) }
        return out
    }

    func changedMovements(since: Int64) -> [Movement] {
        var out: [Movement] = []
        rows("SELECT * FROM movement WHERE updated_at > ? ORDER BY updated_at", [.int(since)]) { out.append(readMovement($0)) }
        return out
    }

    func allCategories() -> [Category] { categories(includeInactive: true) }

    func allBatches() -> [Batch] {
        var out: [Batch] = []
        rows("SELECT * FROM batch", []) { out.append(readBatch($0)) }
        return out
    }

    func allMovements() -> [Movement] {
        var out: [Movement] = []
        rows("SELECT * FROM movement", []) { out.append(readMovement($0)) }
        return out
    }

    func applyRemote(categories: [Category], batches: [Batch], movements: [Movement]) throws {
        try run("BEGIN IMMEDIATE")
        do {
            for c in categories where c.updatedAt >= (self.category(id: c.id)?.updatedAt ?? 0) {
                try upsertCategory(c)
            }
            for b in batches {
                var localUpdated: Int64 = 0
                rows("SELECT updated_at FROM batch WHERE id = ?", [.text(b.id)]) { localUpdated = int($0, 0) }
                guard b.updatedAt >= localUpdated else { continue }
                try run("""
                INSERT INTO batch(id, category_id, batch_no, supplier, origin, received_at,
                                  qty_in_centijin, qty_left_centijin, unit_cost_cent, note, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    category_id = excluded.category_id, batch_no = excluded.batch_no,
                    supplier = excluded.supplier, origin = excluded.origin,
                    received_at = excluded.received_at, qty_in_centijin = excluded.qty_in_centijin,
                    qty_left_centijin = excluded.qty_left_centijin,
                    unit_cost_cent = excluded.unit_cost_cent, note = excluded.note,
                    updated_at = excluded.updated_at, deleted = excluded.deleted
                """, [.text(b.id), .text(b.categoryID), .text(b.batchNo), .text(b.supplier),
                      .text(b.origin), .int(b.receivedAt), .int(Int64(b.qtyInCentijin)),
                      .int(Int64(b.qtyLeftCentijin)), .int(Int64(b.unitCostCent)),
                      .text(b.note), .int(b.updatedAt), .int(b.deleted ? 1 : 0)])
            }
            for m in movements {
                var localUpdated: Int64 = 0
                rows("SELECT updated_at FROM movement WHERE id = ?", [.text(m.id)]) { localUpdated = int($0, 0) }
                guard m.updatedAt >= localUpdated else { continue }
                try run("""
                INSERT INTO movement(id, ts, kind, category_id, batch_id, qty_centijin,
                                     unit_price_cent, amount_cent, party, operator, doc_no, note, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ts = excluded.ts, kind = excluded.kind, category_id = excluded.category_id,
                    batch_id = excluded.batch_id, qty_centijin = excluded.qty_centijin,
                    unit_price_cent = excluded.unit_price_cent,
                    amount_cent = excluded.amount_cent, party = excluded.party,
                    operator = excluded.operator, doc_no = excluded.doc_no,
                    note = excluded.note, updated_at = excluded.updated_at,
                    deleted = excluded.deleted
                """, [.text(m.id), .int(m.ts), .text(m.kind.rawValue), .text(m.categoryID),
                      m.batchID.map { Value.text($0) } ?? .null, .int(Int64(m.qtyCentijin)),
                      .int(Int64(m.unitPriceCent)), .int(Int64(m.amountCent)), .text(m.party),
                      .text(m.operatorName), .text(m.docNo), .text(m.note),
                      .int(m.updatedAt), .int(m.deleted ? 1 : 0)])
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func replaceAll(categories: [Category], batches: [Batch], movements: [Movement]) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM movement", [])
            try run("DELETE FROM batch", [])
            try run("DELETE FROM category", [])
            for c in categories { try upsertCategory(c) }
            for b in batches {
                try run("""
                INSERT OR REPLACE INTO batch(id, category_id, batch_no, supplier, origin, received_at,
                    qty_in_centijin, qty_left_centijin, unit_cost_cent, note, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(b.id), .text(b.categoryID), .text(b.batchNo), .text(b.supplier),
                      .text(b.origin), .int(b.receivedAt), .int(Int64(b.qtyInCentijin)),
                      .int(Int64(b.qtyLeftCentijin)), .int(Int64(b.unitCostCent)),
                      .text(b.note), .int(b.updatedAt), .int(b.deleted ? 1 : 0)])
            }
            for m in movements {
                try run("""
                INSERT OR REPLACE INTO movement(id, ts, kind, category_id, batch_id, qty_centijin,
                    unit_price_cent, amount_cent, party, operator, doc_no, note, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(m.id), .int(m.ts), .text(m.kind.rawValue), .text(m.categoryID),
                      m.batchID.map { Value.text($0) } ?? .null, .int(Int64(m.qtyCentijin)),
                      .int(Int64(m.unitPriceCent)), .int(Int64(m.amountCent)), .text(m.party),
                      .text(m.operatorName), .text(m.docNo), .text(m.note), .int(m.updatedAt),
                      .int(m.deleted ? 1 : 0)])
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 供应商 / 客户历史

    func addPartyName(_ kind: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? run("""
        INSERT INTO party_history(kind, name, used_at) VALUES (?, ?, ?)
        ON CONFLICT(kind, name) DO UPDATE SET used_at = excluded.used_at
        """, [.text(kind), .text(trimmed), .int(Fmt.millis())])
    }

    func partyNames(_ kind: String, limit: Int = 30) -> [String] {
        var out: [String] = []
        rows("SELECT name FROM party_history WHERE kind = ? ORDER BY used_at DESC LIMIT ?",
             [.text(kind), .int(Int64(limit))]) { out.append(text($0, 0)) }
        return out
    }

    // MARK: - 演示数据

    /// 只在“这台机器第一次打开 App”时灌演示数据。
    /// 清空数据后 seeded 会回到 0，但 init_done 仍是 1，因此不会再自动灌回来。
    func seedIfNeeded() {
        if setting("init_done") == "1" || setting("seeded") == "1" {
            setSetting("init_done", "1")
            return
        }
        seedDemoData()
        setSetting("seeded", "1")
        setSetting("init_done", "1")
    }

    /// 关于页双击「数据存储」用：写入一份演示数据，并把写入的行记进 demo_mark，
    /// 之后再双击可以只删这些行，不会碰到用户自己录的数据。
    func seedDemoNow() {
        let catBefore = Set(allCategories().map { $0.id })
        let batchBefore = Set(allBatches().map { $0.id })
        let moveBefore = Set(allMovements().map { $0.id })
        seedDemoData()
        for row in allCategories() where !catBefore.contains(row.id) { markDemo("category", row.id) }
        for row in allBatches() where !batchBefore.contains(row.id) { markDemo("batch", row.id) }
        for row in allMovements() where !moveBefore.contains(row.id) { markDemo("movement", row.id) }
        setSetting("seeded", "1")
        setSetting("init_done", "1")
    }

    func hasDemoData() -> Bool {
        var count = 0
        rows("SELECT COUNT(*) FROM demo_mark", []) { count = Int(int($0, 0)) }
        return count > 0
    }

    private func markDemo(_ kind: String, _ id: String) {
        try? run("INSERT OR IGNORE INTO demo_mark(kind, id) VALUES (?, ?)", [.text(kind), .text(id)])
    }

    /// 只删演示数据（按 demo_mark 记录的行），用户手工录入的品类/流水一条不动。
    func clearDemoData() {
        func ids(_ kind: String) -> [String] {
            var out: [String] = []
            rows("SELECT id FROM demo_mark WHERE kind = ?", [.text(kind)]) { out.append(text($0, 0)) }
            return out
        }
        try? run("BEGIN IMMEDIATE")
        for id in ids("movement") { try? run("DELETE FROM movement WHERE id = ?", [.text(id)]) }
        for id in ids("batch") { try? run("DELETE FROM batch WHERE id = ?", [.text(id)]) }
        for id in ids("category") { try? run("DELETE FROM category WHERE id = ?", [.text(id)]) }
        try? run("DELETE FROM demo_mark")
        try? run("COMMIT")
        setSetting("seeded", "0")
    }

    // MARK: - 审计日志

    struct AuditEntry: Identifiable {
        var id: String
        var ts: Int64
        var operatorName: String
        var action: String
        var target: String
        var detail: String
        var batchID: String = ""
        var beforeText: String = ""
        var afterText: String = ""
        var reason: String = ""
    }

    func logAudit(action: String, target: String, detail: String, operatorName: String? = nil,
                  batchID: String = "", beforeText: String = "", afterText: String = "", reason: String = "") {
        var name = operatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { name = setting("operator") }
        if name.isEmpty { name = "未署名" }
        let now = Fmt.millis()
        try? run("INSERT INTO audit_log(id, ts, operator, action, target, detail, updated_at, batch_id, before_text, after_text, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                 [.text(UUID().uuidString), .int(now), .text(name),
                  .text(action), .text(target), .text(detail), .int(now),
                  .text(batchID), .text(beforeText), .text(afterText), .text(reason)])
    }

    func auditEntries(limit: Int = 300) -> [AuditEntry] {
        var out: [AuditEntry] = []
        rows("SELECT id, ts, operator, action, target, detail, batch_id, before_text, after_text, reason FROM audit_log ORDER BY ts DESC LIMIT ?",
             [.int(Int64(limit))]) { st in
            out.append(AuditEntry(id: text(st, 0), ts: int(st, 1), operatorName: text(st, 2),
                                  action: text(st, 3), target: text(st, 4), detail: text(st, 5),
                                  batchID: text(st, 6), beforeText: text(st, 7),
                                  afterText: text(st, 8), reason: text(st, 9)))
        }
        return out
    }

    /// 某个批次的修改记录（新的在前）
    func corrections(batchID: String, limit: Int = 20) -> [AuditEntry] {
        var out: [AuditEntry] = []
        rows("SELECT id, ts, operator, action, target, detail, batch_id, before_text, after_text, reason FROM audit_log WHERE batch_id = ? ORDER BY ts DESC LIMIT ?",
             [.text(batchID), .int(Int64(limit))]) { st in
            out.append(AuditEntry(id: text(st, 0), ts: int(st, 1), operatorName: text(st, 2),
                                  action: text(st, 3), target: text(st, 4), detail: text(st, 5),
                                  batchID: text(st, 6), beforeText: text(st, 7),
                                  afterText: text(st, 8), reason: text(st, 9)))
        }
        return out
    }

    func changedAudits(since: Int64) -> [AuditEntry] {
        var out: [AuditEntry] = []
        rows("SELECT id, ts, operator, action, target, detail, batch_id, before_text, after_text, reason FROM audit_log WHERE updated_at > ? ORDER BY updated_at",
             [.int(since)]) { st in
            out.append(AuditEntry(id: text(st, 0), ts: int(st, 1), operatorName: text(st, 2),
                                  action: text(st, 3), target: text(st, 4), detail: text(st, 5),
                                  batchID: text(st, 6), beforeText: text(st, 7),
                                  afterText: text(st, 8), reason: text(st, 9)))
        }
        return out
    }

    func allAudits() -> [AuditEntry] {
        var out: [AuditEntry] = []
        rows("SELECT id, ts, operator, action, target, detail, batch_id, before_text, after_text, reason FROM audit_log", []) { st in
            out.append(AuditEntry(id: text(st, 0), ts: int(st, 1), operatorName: text(st, 2),
                                  action: text(st, 3), target: text(st, 4), detail: text(st, 5),
                                  batchID: text(st, 6), beforeText: text(st, 7),
                                  afterText: text(st, 8), reason: text(st, 9)))
        }
        return out
    }

    /// 远程拉回来的审计：追加，不覆盖本地已有记录（审计只增不减）
    func applyRemoteAudits(_ entries: [AuditEntry]) throws {
        for entry in entries {
            try run("INSERT OR IGNORE INTO audit_log(id, ts, operator, action, target, detail, updated_at, batch_id, before_text, after_text, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(entry.id), .int(entry.ts), .text(entry.operatorName),
                     .text(entry.action), .text(entry.target), .text(entry.detail), .int(entry.ts),
                     .text(entry.batchID), .text(entry.beforeText), .text(entry.afterText), .text(entry.reason)])
        }
    }

    func replaceAudits(_ entries: [AuditEntry]) throws {
        try run("DELETE FROM audit_log", [])
        try applyRemoteAudits(entries)
    }

    // MARK: - 批次校正（留痕）

    struct BatchCorrection {
        var batchID: String
        var newCategoryID: String
        var newQtyCentijin: Int
        var supplier: String
        var origin: String
        var note: String
        var reason: String
        var operatorName: String
    }

    func correctBatch(_ input: BatchCorrection) throws {
        guard let batch = allBatches().first(where: { $0.id == input.batchID }) else {
            throw InventoryError.message("批次不存在")
        }
        let reason = input.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw InventoryError.message("请填写校正原因") }
        guard input.newQtyCentijin >= 0 else { throw InventoryError.message("数量不能为负") }
        if batch.categoryID != input.newCategoryID, category(id: input.newCategoryID) == nil {
            throw InventoryError.message("目标品类不存在")
        }

        let now = Fmt.millis()
        var changes: [String] = []
        try run("BEGIN IMMEDIATE")
        do {
            if batch.categoryID != input.newCategoryID {
                let fromName = category(id: batch.categoryID)?.name ?? batch.categoryID
                let toName = category(id: input.newCategoryID)?.name ?? input.newCategoryID
                try run("UPDATE batch SET category_id = ?, updated_at = ? WHERE id = ?",
                        [.text(input.newCategoryID), .int(now), .text(batch.id)])
                try run("UPDATE movement SET category_id = ?, updated_at = ? WHERE batch_id = ?",
                        [.text(input.newCategoryID), .int(now), .text(batch.id)])
                changes.append("品类 " + fromName + " → " + toName)
            }

            let diff = input.newQtyCentijin - batch.qtyLeftCentijin
            if diff != 0 {
                try run("UPDATE batch SET qty_left_centijin = ?, updated_at = ? WHERE id = ?",
                        [.int(Int64(input.newQtyCentijin)), .int(now), .text(batch.id)])
                let kind: MovementKind = diff > 0 ? .count : .loss
                try insertMovement(Movement(id: UUID().uuidString, ts: now, kind: kind,
                                            categoryID: input.newCategoryID, batchID: batch.id,
                                            qtyCentijin: diff, unitPriceCent: batch.unitCostCent,
                                            amountCent: 0, party: "", operatorName: input.operatorName,
                                            docNo: try nextDocNo(prefix: "JZ", date: Date()),
                                            note: "批次校正：" + reason, updatedAt: now, deleted: false))
                changes.append("数量 " + Units.formatJin(batch.qtyLeftCentijin) + " → " + Units.formatJin(input.newQtyCentijin) + " 斤")
            }

            let supplier = input.supplier.trimmingCharacters(in: .whitespacesAndNewlines)
            let origin = input.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = input.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if supplier != batch.supplier || origin != batch.origin || note != batch.note {
                try run("UPDATE batch SET supplier = ?, origin = ?, note = ?, updated_at = ? WHERE id = ?",
                        [.text(supplier), .text(origin), .text(note), .int(now), .text(batch.id)])
                changes.append("来源/备注已改")
            }
            let oldCatName = category(id: batch.categoryID)?.name ?? ""
            let newCatName = category(id: input.newCategoryID)?.name ?? ""
            let beforeText = oldCatName + " · " + Units.formatJin(batch.qtyLeftCentijin) + " 斤 · "
                + (batch.supplier.isEmpty ? "—" : batch.supplier) + "/" + (batch.origin.isEmpty ? "—" : batch.origin)
            let afterText = newCatName + " · " + Units.formatJin(input.newQtyCentijin) + " 斤 · "
                + (input.supplier.isEmpty ? "—" : input.supplier) + "/" + (input.origin.isEmpty ? "—" : input.origin)

            var operator = input.operatorName.trimmingCharacters(in: .whitespacesAndNewlines)
            if operator.isEmpty { operator = setting("operator") }
            if operator.isEmpty { operator = "未署名" }
            try run("INSERT INTO audit_log(id, ts, operator, action, target, detail, updated_at, batch_id, before_text, after_text, reason) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(UUID().uuidString), .int(now), .text(operator), .text("批次校正"),
                     .text(batch.batchNo + "（" + newCatName + "）"),
                     .text((changes.isEmpty ? "无字段变化" : changes.joined(separator: "；")) + "；原因：" + reason),
                     .int(now), .text(batch.id), .text(beforeText), .text(afterText), .text(reason)])
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    // MARK: - 备份导出 / 导入

    struct BackupFile: Codable {
        var format: String
        var exportedAt: String
        var categories: [Category]
        var batches: [Batch]
        var movements: [Movement]
        var parties: [[String: String]]
    }

    func exportBackup() throws -> Data {
        var parties: [[String: String]] = []
        rows("SELECT kind, name FROM party_history ORDER BY used_at DESC", []) { st in
            parties.append(["kind": text(st, 0), "name": text(st, 1)])
        }
        let file = BackupFile(format: "seafood-backup-1",
                              exportedAt: ISO8601DateFormatter().string(from: Date()),
                              categories: allCategories(),
                              batches: allBatches(),
                              movements: allMovements(),
                              parties: parties)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    func importBackup(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(BackupFile.self, from: data)
        guard decoded.format.hasPrefix("seafood-backup") else {
            throw InventoryError.message("不是本 App 的备份文件")
        }
        try replaceAll(categories: decoded.categories, batches: decoded.batches, movements: decoded.movements)
        try? run("DELETE FROM party_history")
        for item in decoded.parties {
            if let kind = item["kind"], let name = item["name"] {
                addPartyName(kind, name)
            }
        }
        setSetting("init_done", "1")
        setSetting("seeded", "0")
    }

    private func seedDemoData() {
        let cats: [(String, StorageKind, Double)] = [
            ("基围虾", .chilled, 150), ("三文鱼", .frozen, 200),
            ("南美白对虾", .frozen, 120), ("花蛤", .live, 80),
            ("鲈鱼", .live, 50), ("生蚝", .chilled, 100),
            ("梭子蟹", .live, 60), ("小黄鱼", .frozen, 130)
        ]
        var ids: [String: String] = [:]
        for (name, storage, warn) in cats {
            if let c = try? createCategory(name: name, storage: storage, warnJin: warn, allowNegative: false) {
                ids[name] = c.id
            }
        }
        let ins: [(String, Double, Double, String, String, TimeInterval)] = [
            ("基围虾", 60, 43, "北海港口", "北海", -2 * 86400 - 6 * 3600),
            ("三文鱼", 240, 58.8, "北海冻品", "挪威", -4 * 86400),
            ("南美白对虾", 120, 31.4, "北海冻品", "北海", -3 * 86400),
            ("花蛤", 200, 9.9, "北海铁山港", "北海", -86400),
            ("鲈鱼", 96, 18.5, "北海本地塘口", "北海", -2 * 86400),
            ("生蚝", 100, 22, "北海", "北海", -3 * 86400),
            ("梭子蟹", 160.5, 65, "北海涠洲", "北海", -86400),
            ("小黄鱼", 120, 15, "北海冻品", "北海", -4 * 86400),
            ("基围虾", 120, 42.5, "北海港口", "北海", -86400),
            ("基围虾", 60, 41, "北海港口", "北海", -3600),
            ("三文鱼", 40, 57, "北海冻品", "挪威", -3000),
            ("南美白对虾", 150.2, 30.8, "北海冻品", "北海", -86400),
            ("花蛤", 26, 9.6, "北海铁山港", "北海", -2400)
        ]
        for (name, jin, cost, supplier, origin, offset) in ins {
            guard let id = ids[name] else { continue }
            _ = try? inbound(categoryID: id, newCategoryName: nil, storage: .chilled,
                             jin: jin, unitCost: cost, supplier: supplier, origin: origin,
                             note: "", at: Date().addingTimeInterval(offset))
        }
        let outs: [(String, Double, Double, String, TimeInterval)] = [
            ("基围虾", 28, 43.5, "老陈水产", -2 * 86400),
            ("三文鱼", 26, 59, "日料小町", -86400),
            ("花蛤", 20, 10.2, "阿强排档", -86400),
            ("南美白对虾", 12, 32, "海港酒楼", -86400),
            ("基围虾", 32, 42, "老陈水产", -3600),
            ("南美白对虾", 12, 33, "老陈水产", -3000),
            ("花蛤", 25.5, 9.8, "阿强排档", -2400),
            ("生蚝", 8, 25, "海港酒楼", -1800),
            ("梭子蟹", 18, 65, "海港酒楼", -1200),
            ("三文鱼", 13, 58.5, "日料小町", -600)
        ]
        for (name, jin, price, party, offset) in outs {
            guard let id = ids[name] else { continue }
            let item = OutItemInput(categoryID: id, centijin: Units.centijin(fromJin: jin),
                                    unitPriceCent: Units.cent(fromYuan: price))
            _ = try? outbound(customer: party, items: [item], at: Date().addingTimeInterval(offset))
        }
    }

    func resetAll() {
        exec("DELETE FROM movement; DELETE FROM batch; DELETE FROM category;")
        setSetting("seeded", "0")
    }
}
