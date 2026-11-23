//
//  SyncEngine.swift
//  SeafoodInventory
//
//  同步引擎：本地 SQLite ⇄ 远程 MySQL（sf_* 表），先推后拉，LWW（updated_at 大者胜）合并。
//
//  ⚠️ 未编译验证：当前环境没有 Xcode / swiftc，本文件只做了逐行人工检查 + 脚本化括号/插值自查，
//  没有编译过，也没有连真实 MySQL 跑过。集成后请先 testConnection()，再 syncNow()。
//
//  线程模型（硬约束）：
//  1. SQLiteStore 只有一条 sqlite3 连接、事务跨多次调用，所以**所有 SQLiteStore 调用都在 MainActor 上**：
//     lastSyncAt / changedCategories / changedBatches / changedMovements / applyRemote / replaceAll / setting。
//  2. MySQL 的网络、握手、结果集解析全部在一条后台串行队列（workQueue）上，由 SyncSession 驱动。
//  3. 数据以纯值类型（LocalChanges / RemoteSnapshot）在两段之间传递：主线程取本地变更 → 后台推送 →
//     后台拉取 → 回主线程落库 → 后台写远程游标 → 回主线程写本地游标。
//  4. @Published 的 state / lastSync 只在 MainActor 上写；同一时刻只允许一个同步在跑（acquire/release 串行闸门）。
//
//  游标语义：
//  - 本地游标 = SQLiteStore.setting("sync_last_at")，表示「本地 updated_at ≤ 游标 的行已经推过远程」。
//  - 远程游标 = 远程 sf_meta.k='watermark'（毫秒），表示「远程 updated_at ≤ 游标 的行已经拉过」。
//  - 远端时钟可能比本机快，所以本地游标会被 min(拉取最大值, 当前毫秒) 夹一次，
//    保证本机后来的修改一定大于本地游标、能被推出去。
//

import Foundation
import Combine

// MARK: - 状态

enum SyncState: Equatable {
    case idle
    case syncing
    case success(Date)
    case failed(String)
}

struct SyncReport: Equatable {
    var pushed: Int
    var pulled: Int
    var at: Date
}

// MARK: - 跨线程搬运的数据

/// 本地待推送的变更集合（主线程组装，后台消费）。
struct LocalChanges {
    var categories: [Category] = []
    var batches: [Batch] = []
    var movements: [Movement] = []

    var count: Int { categories.count + batches.count + movements.count }
    var isEmpty: Bool { count == 0 }
}

/// 远程拉取结果（后台组装，主线程落库）。
struct RemoteSnapshot {
    var categories: [Category] = []
    var batches: [Batch] = []
    var movements: [Movement] = []
    var maxUpdatedAt: Int64 = 0

    var count: Int { categories.count + batches.count + movements.count }
}

// MARK: - 后台会话（只碰 MySQL，绝不碰 SQLiteStore）

/// 一个同步周期一个实例：open 时建链 + 建表 + 读远程游标，用完 close。
final class SyncSession {
    private static let rowsPerStatement = 200

    private let client: MySQLClient
    /// open 时读到的远程游标，pull 用它做增量条件
    let remoteWatermark: Int64

    private init(client: MySQLClient, remoteWatermark: Int64) {
        self.client = client
        self.remoteWatermark = remoteWatermark
    }

    static func open(config: MySQLConfig) throws -> SyncSession {
        let client = MySQLClient(config: config)
        do {
            try client.connect()
            try ensureSchema(client)
            let watermark = try readWatermark(client)
            return SyncSession(client: client, remoteWatermark: watermark)
        } catch {
            client.close()
            throw error
        }
    }

    func close() {
        client.close()
    }

    // MARK: 推送

    func push(_ changes: LocalChanges) throws -> (count: Int, maxUpdatedAt: Int64) {
        var count = 0
        var maxUpdated: Int64 = 0

        for chunk in changes.categories.chunked(SyncSession.rowsPerStatement) {
            let tuples = chunk.map { row in
                "(" + [
                    SQL.text(row.id),
                    SQL.text(row.name),
                    SQL.text(row.storage.rawValue),
                    SQL.int(row.warnCentijin),
                    SQL.bool(row.allowNegative),
                    SQL.int(row.sort),
                    SQL.bool(row.active),
                    SQL.int64(row.createdAt),
                    SQL.int64(row.updatedAt),
                    SQL.bool(row.deleted)
                ].joined(separator: ",") + ")"
            }.joined(separator: ",")
            _ = try client.execute("REPLACE INTO sf_category"
                + "(id,name,storage,warn_centijin,allow_negative,sort,active,created_at,updated_at,deleted)"
                + " VALUES " + tuples)
            count += chunk.count
            maxUpdated = max(maxUpdated, SyncSession.maxUpdated(chunk.map { $0.updatedAt }))
        }

        for chunk in changes.batches.chunked(SyncSession.rowsPerStatement) {
            let tuples = chunk.map { row in
                "(" + [
                    SQL.text(row.id),
                    SQL.text(row.categoryID),
                    SQL.text(row.batchNo),
                    SQL.text(row.supplier),
                    SQL.text(row.origin),
                    SQL.int64(row.receivedAt),
                    SQL.int(row.qtyInCentijin),
                    SQL.int(row.qtyLeftCentijin),
                    SQL.int(row.unitCostCent),
                    SQL.text(row.note),
                    SQL.int64(row.updatedAt),
                    SQL.bool(row.deleted)
                ].joined(separator: ",") + ")"
            }.joined(separator: ",")
            _ = try client.execute("REPLACE INTO sf_batch"
                + "(id,category_id,batch_no,supplier,origin,received_at,qty_in_centijin,"
                + "qty_left_centijin,unit_cost_cent,note,updated_at,deleted)"
                + " VALUES " + tuples)
            count += chunk.count
            maxUpdated = max(maxUpdated, SyncSession.maxUpdated(chunk.map { $0.updatedAt }))
        }

        for chunk in changes.movements.chunked(SyncSession.rowsPerStatement) {
            let tuples = chunk.map { row in
                "(" + [
                    SQL.text(row.id),
                    SQL.int64(row.ts),
                    SQL.text(row.kind.rawValue),
                    SQL.text(row.categoryID),
                    SQL.text(row.batchID),
                    SQL.int(row.qtyCentijin),
                    SQL.int(row.unitPriceCent),
                    SQL.int(row.amountCent),
                    SQL.text(row.party),
                    SQL.text(row.operatorName),
                    SQL.text(row.docNo),
                    SQL.text(row.note),
                    SQL.int64(row.updatedAt),
                    SQL.bool(row.deleted)
                ].joined(separator: ",") + ")"
            }.joined(separator: ",")
            _ = try client.execute("REPLACE INTO sf_movement"
                + "(id,ts,kind,category_id,batch_id,qty_centijin,unit_price_cent,amount_cent,"
                + "party,operator,doc_no,note,updated_at,deleted)"
                + " VALUES " + tuples)
            count += chunk.count
            maxUpdated = max(maxUpdated, SyncSession.maxUpdated(chunk.map { $0.updatedAt }))
        }

        return (count, maxUpdated)
    }

    private static func maxUpdated(_ values: [Int64]) -> Int64 {
        var result: Int64 = 0
        for value in values where value > result {
            result = value
        }
        return result
    }

    // MARK: 拉取

    /// 增量拉取：远程 updated_at > open 时的远程游标。
    func pull() throws -> RemoteSnapshot {
        try fetch(since: remoteWatermark)
    }

    /// 全量拉取：pullReplace 用。
    func fetchAll() throws -> RemoteSnapshot {
        try fetch(since: nil)
    }

    private func fetch(since cursor: Int64?) throws -> RemoteSnapshot {
        var snapshot = RemoteSnapshot()
        let condition: String
        if let cursor {
            condition = " WHERE updated_at > " + String(cursor)
        } else {
            condition = ""
        }

        let categoryRows = try client.query("SELECT id,name,storage,warn_centijin,allow_negative,"
            + "sort,active,created_at,updated_at,deleted FROM sf_category"
            + condition + " ORDER BY updated_at")
        snapshot.categories.reserveCapacity(categoryRows.count)
        for raw in categoryRows {
            let row = Row(raw)
            snapshot.categories.append(Category(
                id: row.text("id"),
                name: row.text("name"),
                storage: StorageKind(rawValue: row.text("storage")) ?? .chilled,
                warnCentijin: row.int("warn_centijin"),
                allowNegative: row.bool("allow_negative"),
                sort: row.int("sort"),
                active: row.bool("active"),
                createdAt: row.int64("created_at"),
                updatedAt: row.int64("updated_at"),
                deleted: row.bool("deleted")
            ))
            snapshot.maxUpdatedAt = max(snapshot.maxUpdatedAt, row.int64("updated_at"))
        }

        let batchRows = try client.query("SELECT id,category_id,batch_no,supplier,origin,received_at,"
            + "qty_in_centijin,qty_left_centijin,unit_cost_cent,note,updated_at,deleted FROM sf_batch"
            + condition + " ORDER BY updated_at")
        snapshot.batches.reserveCapacity(batchRows.count)
        for raw in batchRows {
            let row = Row(raw)
            snapshot.batches.append(Batch(
                id: row.text("id"),
                categoryID: row.text("category_id"),
                batchNo: row.text("batch_no"),
                supplier: row.text("supplier"),
                origin: row.text("origin"),
                receivedAt: row.int64("received_at"),
                qtyInCentijin: row.int("qty_in_centijin"),
                qtyLeftCentijin: row.int("qty_left_centijin"),
                unitCostCent: row.int("unit_cost_cent"),
                note: row.text("note"),
                updatedAt: row.int64("updated_at"),
                deleted: row.bool("deleted")
            ))
            snapshot.maxUpdatedAt = max(snapshot.maxUpdatedAt, row.int64("updated_at"))
        }

        let movementRows = try client.query("SELECT id,ts,kind,category_id,batch_id,qty_centijin,"
            + "unit_price_cent,amount_cent,party,operator,doc_no,note,updated_at,deleted FROM sf_movement"
            + condition + " ORDER BY updated_at")
        snapshot.movements.reserveCapacity(movementRows.count)
        for raw in movementRows {
            let row = Row(raw)
            let batchID = row.optText("batch_id").flatMap { $0.isEmpty ? nil : $0 }
            snapshot.movements.append(Movement(
                id: row.text("id"),
                ts: row.int64("ts"),
                kind: MovementKind(rawValue: row.text("kind")) ?? .in,
                categoryID: row.text("category_id"),
                batchID: batchID,
                qtyCentijin: row.int("qty_centijin"),
                unitPriceCent: row.int("unit_price_cent"),
                amountCent: row.int("amount_cent"),
                party: row.text("party"),
                operatorName: row.text("operator"),
                docNo: row.text("doc_no"),
                note: row.text("note"),
                updatedAt: row.int64("updated_at"),
                deleted: row.bool("deleted")
            ))
            snapshot.maxUpdatedAt = max(snapshot.maxUpdatedAt, row.int64("updated_at"))
        }

        return snapshot
    }

    // MARK: 远程游标

    func writeWatermark(_ value: Int64) throws {
        _ = try client.execute("REPLACE INTO sf_meta(k,v) VALUES ('watermark','" + String(value) + "')")
    }

    private static func readWatermark(_ client: MySQLClient) throws -> Int64 {
        let rows = try client.query("SELECT v FROM sf_meta WHERE k = 'watermark'")
        guard let first = rows.first else { return 0 }
        let row = Row(first)
        let raw = row.optText("v")
        guard let text = raw, let value = Int64(text) else { return 0 }
        return value > 0 ? value : 0
    }

    // MARK: 建表

    private static func ensureSchema(_ client: MySQLClient) throws {
        _ = try client.execute("""
        CREATE TABLE IF NOT EXISTS sf_category(
            id varchar(64) NOT NULL,
            name varchar(120) NOT NULL DEFAULT '',
            storage varchar(16) NOT NULL DEFAULT '',
            warn_centijin int NOT NULL DEFAULT 0,
            allow_negative tinyint NOT NULL DEFAULT 0,
            sort int NOT NULL DEFAULT 0,
            active tinyint NOT NULL DEFAULT 1,
            created_at bigint NOT NULL DEFAULT 0,
            updated_at bigint NOT NULL DEFAULT 0,
            deleted tinyint NOT NULL DEFAULT 0,
            PRIMARY KEY (id),
            KEY idx_updated(updated_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
        _ = try client.execute("""
        CREATE TABLE IF NOT EXISTS sf_batch(
            id varchar(64) NOT NULL,
            category_id varchar(64) NOT NULL DEFAULT '',
            batch_no varchar(40) NOT NULL DEFAULT '',
            supplier varchar(120) NOT NULL DEFAULT '',
            origin varchar(120) NOT NULL DEFAULT '',
            received_at bigint NOT NULL DEFAULT 0,
            qty_in_centijin int NOT NULL DEFAULT 0,
            qty_left_centijin int NOT NULL DEFAULT 0,
            unit_cost_cent int NOT NULL DEFAULT 0,
            note varchar(255) NOT NULL DEFAULT '',
            updated_at bigint NOT NULL DEFAULT 0,
            deleted tinyint NOT NULL DEFAULT 0,
            PRIMARY KEY (id),
            KEY idx_cat(category_id, received_at),
            KEY idx_updated(updated_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
        _ = try client.execute("""
        CREATE TABLE IF NOT EXISTS sf_movement(
            id varchar(64) NOT NULL,
            ts bigint NOT NULL DEFAULT 0,
            kind varchar(8) NOT NULL DEFAULT '',
            category_id varchar(64) NOT NULL DEFAULT '',
            batch_id varchar(64) NULL,
            qty_centijin int NOT NULL DEFAULT 0,
            unit_price_cent int NOT NULL DEFAULT 0,
            amount_cent int NOT NULL DEFAULT 0,
            party varchar(120) NOT NULL DEFAULT '',
            operator varchar(60) NOT NULL DEFAULT '',
            doc_no varchar(40) NOT NULL DEFAULT '',
            note varchar(255) NOT NULL DEFAULT '',
            updated_at bigint NOT NULL DEFAULT 0,
            deleted tinyint NOT NULL DEFAULT 0,
            PRIMARY KEY (id),
            KEY idx_ts(ts),
            KEY idx_updated(updated_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
        _ = try client.execute("""
        CREATE TABLE IF NOT EXISTS sf_meta(
            k varchar(64) NOT NULL,
            v varchar(255) NOT NULL DEFAULT '',
            PRIMARY KEY (k)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
        """)
    }
}

// MARK: - SQL 字面量

/// 拼 SQL 时统一走这里：单引号双写 + 反斜杠/控制字符转义，避免注入和截断。
enum SQL {
    static func text(_ value: String?) -> String {
        guard let value else { return "NULL" }
        var out = "'"
        for scalar in value.unicodeScalars {
            switch scalar {
            case "'":
                out += "''"
            case "\\":
                out += "\\\\"
            case "\u{00}":
                out += "\\0"
            case "\u{0A}":
                out += "\\n"
            case "\u{0D}":
                out += "\\r"
            case "\u{1A}":
                out += "\\Z"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "'"
        return out
    }

    static func int(_ value: Int) -> String {
        String(value)
    }

    static func int64(_ value: Int64) -> String {
        String(value)
    }

    static func bool(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}

// MARK: - 结果行

/// 结果集的单行包装：所有 MySQL 值在客户端已经转成字符串，这里只做类型收口。
private struct Row {
    private let values: [String: String?]

    init(_ values: [String: String?]) {
        self.values = values
    }

    func text(_ key: String) -> String {
        guard let cell = values[key] else { return "" }
        return cell ?? ""
    }

    func optText(_ key: String) -> String? {
        guard let cell = values[key] else { return nil }
        if let text = cell { return text }
        return nil
    }

    func int(_ key: String) -> Int {
        Int(int64(key))
    }

    func int64(_ key: String) -> Int64 {
        guard let cell = values[key], let text = cell, let value = Int64(text) else { return 0 }
        return value
    }

    func bool(_ key: String) -> Bool {
        int64(key) != 0
    }
}

// MARK: - 数组分片

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var start = 0
        while start < count {
            let end = Swift.min(start + size, count)
            result.append(Array(self[start..<end]))
            start = end
        }
        return result
    }
}

// MARK: - 引擎

@MainActor
final class SyncEngine: ObservableObject {
    /// 说明：类本身仍是 @MainActor，shared 用 nonisolated 是为了让 App / Preview 在非隔离上下文也能引用；
    /// 因此 init 也必须是 nonisolated —— 它不碰 SQLiteStore，只从 UserDefaults 镜像里恢复上次同步时间。
    nonisolated static let shared = SyncEngine()

    @Published private(set) var state: SyncState = .idle
    @Published private(set) var lastSync: Date?

    private static let lastSyncMirrorKey = "mysql.lastSyncAt"

    private let store: SQLiteStore
    private let workQueue = DispatchQueue(label: "com.yoyulyvw.seafood.sync", qos: .utility)

    private var debounce: DispatchWorkItem?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init(store: SQLiteStore = .shared) {
        self.store = store
        let mirror = UserDefaults.standard.double(forKey: SyncEngine.lastSyncMirrorKey)
        self._lastSync = Published(initialValue: mirror > 0 ? Date(timeIntervalSince1970: mirror) : nil)
    }

    // MARK: 配置

    /// 从 setting("mysql_dsn") 解析；未配置或 DSN 非法都返回 nil。
    var config: MySQLConfig? {
        let raw = store.setting("mysql_dsn").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return MySQLConfig.parse(raw)
    }

    var isConfigured: Bool {
        config != nil
    }

    /// 传 nil 表示关闭同步（DSN 写空串）。
    func saveConfig(_ config: MySQLConfig?) {
        if let config {
            store.setSetting("mysql_dsn", config.dsn)
            MySQLClient.resetTLSProbeCache()
        } else {
            store.setSetting("mysql_dsn", "")
            state = .idle
        }
    }

    // MARK: 测试连接

    func testConnection() async throws -> String {
        guard let config = config else {
            let message = "尚未配置 MySQL 连接"
            state = .failed(message)
            throw InventoryError.message(message)
        }
        await acquire()
        defer { release() }
        state = .syncing
        do {
            let version = try await onWorkQueue { () -> String in
                let client = MySQLClient(config: config)
                defer { client.close() }
                try client.connect()
                _ = try client.query("SELECT 1")
                return client.serverVersion
            }
            state = lastSync.map { SyncState.success($0) } ?? .idle
            return version
        } catch {
            state = .failed(text(of: error))
            throw error
        }
    }

    // MARK: 增量同步（先推后拉）

    func syncNow() async throws -> SyncReport {
        guard let config = config else {
            let message = "尚未配置 MySQL 连接，无法同步"
            state = .failed(message)
            throw InventoryError.message(message)
        }
        await acquire()
        defer { release() }
        state = .syncing
        hydrateLastSyncIfNeeded()

        var active: SyncSession?
        do {
            let session = try await onWorkQueue { try SyncSession.open(config: config) }
            active = session

            // 1) 主线程：读本地游标 + 取待推数据
            let localMark = store.lastSyncAt()
            let changes = LocalChanges(
                categories: store.changedCategories(since: localMark),
                batches: store.changedBatches(since: localMark),
                movements: store.changedMovements(since: localMark)
            )

            // 2) 后台：推送
            let pushed = try await onWorkQueue { try session.push(changes) }

            // 3) 后台：拉取（用 open 时读到的远程游标做增量条件）
            let pulled = try await onWorkQueue { try session.pull() }

            // 4) 主线程：LWW 落库
            try store.applyRemote(categories: pulled.categories,
                                  batches: pulled.batches,
                                  movements: pulled.movements)

            // 5) 算新游标：远程取 max(旧游标, 拉到的最值, 推到的最值)，本地再夹一次当前时间
            let now = Fmt.millis()
            let remoteTop = max(pulled.maxUpdatedAt, pushed.maxUpdatedAt)
            let newRemote = max(session.remoteWatermark, remoteTop)
            let localTop = max(pushed.maxUpdatedAt, Swift.min(pulled.maxUpdatedAt, now))
            let newLocal = max(localMark, localTop)

            // 6) 后台：写远程游标；主线程：写本地游标
            try await onWorkQueue { try session.writeWatermark(newRemote) }
            store.setLastSyncAt(newLocal)

            await closeSession(session)
            active = nil

            let report = SyncReport(pushed: pushed.count, pulled: pulled.count, at: Date())
            markSynced(report.at)
            return report
        } catch {
            if let active {
                await closeSession(active)
            }
            state = .failed(text(of: error))
            throw error
        }
    }

    // MARK: 远程全量覆盖本地

    func pullReplace() async throws -> SyncReport {
        guard let config = config else {
            let message = "尚未配置 MySQL 连接，无法同步"
            state = .failed(message)
            throw InventoryError.message(message)
        }
        await acquire()
        defer { release() }
        state = .syncing
        hydrateLastSyncIfNeeded()

        var active: SyncSession?
        do {
            let session = try await onWorkQueue { try SyncSession.open(config: config) }
            active = session

            let snapshot = try await onWorkQueue { try session.fetchAll() }
            try store.replaceAll(categories: snapshot.categories,
                                 batches: snapshot.batches,
                                 movements: snapshot.movements)

            let now = Fmt.millis()
            let newRemote = max(session.remoteWatermark, snapshot.maxUpdatedAt)
            try await onWorkQueue { try session.writeWatermark(newRemote) }
            store.setLastSyncAt(Swift.min(snapshot.maxUpdatedAt, now))

            await closeSession(session)
            active = nil

            let report = SyncReport(pushed: 0, pulled: snapshot.count, at: Date())
            markSynced(report.at)
            return report
        } catch {
            if let active {
                await closeSession(active)
            }
            state = .failed(text(of: error))
            throw error
        }
    }

    // MARK: 写后自动同步（2 秒防抖，fire-and-forget）

    func autoSyncAfterWrite() {
        guard isConfigured else { return }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // 失败已经写进 state（.failed），这里不再打断用户操作
                _ = try? await self.syncNow()
            }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: 内部

    private func markSynced(_ date: Date) {
        state = .success(date)
        lastSync = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: SyncEngine.lastSyncMirrorKey)
    }

    private func hydrateLastSyncIfNeeded() {
        guard lastSync == nil else { return }
        let mark = store.lastSyncAt()
        if mark > 0 {
            lastSync = Date(timeIntervalSince1970: Double(mark) / 1000)
        }
    }

    private func text(of error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription,
           !message.isEmpty {
            return message
        }
        return error.localizedDescription
    }

    /// 串行闸门：同一时刻只允许一个同步/测试在跑，后来的排队。
    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    /// 把一段只碰 MySQL 的工作丢到后台串行队列，结果回 MainActor。
    private func onWorkQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        let queue = workQueue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 关闭后台会话（close 不抛错，但要回后台队列上执行，保证与使用它的调用同线程）。
    private func closeSession(_ session: SyncSession) async {
        let queue = workQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                session.close()
                continuation.resume()
            }
        }
    }
}
