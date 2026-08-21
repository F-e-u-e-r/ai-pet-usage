import Foundation
import SQLite3
@testable import UsageCore

// MARK: - #50 ground truth(第一批:不需新型別即可表達的 contract)
//
// 這些測試描述 cumulative provider 的 accounting contract 與具體 scenario。
// 斷言值為 contract 要求的結果;實作未滿足時即為紅。
//
// 需要 authoritative anchor 型別才能表達的案例(pending recovery、authority validation、
// limits decoupling)於實作階段隨新 API 一併落。

final class OpenCode50GroundTruthTests: XCTestCase {

    private struct Row {
        var id: String
        var ti: Int
        var tu: Int64
        var tc: Int64 = 1_750_000_000_000
    }

    private func makeDb(at url: URL, _ rows: [Row]) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK, "open fixture db")
        defer { sqlite3_close_v2(db) }
        exec(db, """
        CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT NOT NULL,
          title TEXT, model TEXT, cost REAL DEFAULT 0 NOT NULL,
          tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL,
          tokens_reasoning INTEGER DEFAULT 0 NOT NULL, tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
          tokens_cache_write INTEGER DEFAULT 0 NOT NULL, time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL);
        """)
        for r in rows { upsert(db, r) }
    }

    private func update(_ url: URL, _ r: Row) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK, "reopen fixture db")
        defer { sqlite3_close_v2(db) }
        upsert(db, r)
    }

    private func upsert(_ db: OpaquePointer?, _ r: Row) {
        exec(db, """
        INSERT OR REPLACE INTO session VALUES ('\(r.id)','p','/Users/t/proj-a','T',
          '{"id":"m/x"}',0,\(r.ti),0,0,0,0,\(r.tc),\(r.tu));
        """)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
        if let err { sqlite3_free(err) }
    }

    private func coord(_ dir: URL, _ dbURL: URL) -> UsageCoordinator {
        var s = CoreSettings()
        s.enabledProviders = ["opencode"]
        return UsageCoordinator(dataDir: dir, settings: s, adapters: [OpenCodeAdapter(dbURL: dbURL)])
    }

    @discardableResult
    private func runRefresh(_ c: UsageCoordinator) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await c.refresh(); sem.signal() }
        sem.wait()
        return out!
    }

    private func ledger(_ dir: URL) -> UsageLedger {
        UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
    }

    private func ledgerInputTotal(_ dir: URL) -> Int {
        ledger(dir).events.filter { $0.providerId == "opencode" }.reduce(0) { $0 + $1.tokens.input }
    }

    private static let msPerDay: Int64 = 86_400_000

    /// 顯式 zero-delta establishment。
    ///
    /// 無既有 authority 時的唯一建立路徑:把當下絕對計數器定為 baseline、本輪不發事件。
    /// 這是刻意的產品語義 —— 我方開始觀測**之前**就已存在的來源歷史不得被追溯記入,
    /// 否則新安裝當天會出現一筆巨大的偽尖峰。此後只計 establishment 之後真正發生的成長。
    @discardableResult
    private func establish(_ dir: URL, _ dbURL: URL) -> RefreshOutcome {
        let out = runRefresh(coord(dir, dbURL))
        XCTAssertEqual(ledgerInputTotal(dir), 0, "establishment 本身不得產生事件")
        return out
    }

    // MARK: Retention × mark loss
    //
    // Contract:已入帳的 cumulative 用量不得僅因 ledger retention 移除舊 event id 而被再次計算。
    //
    // Scenario:session 的 time_updated 早於保留窗 ⇒ 其首筆事件在次輪 refresh 即被 compaction 移除;
    // 此後 scan-state 遺失、重掃 ⇒ 若無獨立於 retention 的 accounting 權威,將自零重算。
    // 保留窗內的真實成長為 100→300 = 200。
    func testRetentionThenMarkLossMustNotRecount() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let scanURL = dir.appendingPathComponent("scan-state.json")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let old = now - 200 * Self.msPerDay

        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: old)])
        establish(dir, dbURL)                                   // baseline := 100

        update(dbURL, Row(id: "s1", ti: 200, tu: old))          // 成長 100,時間戳仍在保留窗外
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(ledgerInputTotal(dir), 100, "前置:已入帳 100(時間戳逾期)")

        runRefresh(coord(dir, dbURL))                            // compaction 移除該逾期事件
        XCTAssertEqual(ledgerInputTotal(dir), 0, "前置:逾期事件已被壓縮,其 id 亦已自去重集合消失")

        update(dbURL, Row(id: "s1", ti: 300, tu: now))
        try FileManager.default.removeItem(at: scanURL)          // ScanState 遺失
        runRefresh(coord(dir, dbURL))

        XCTAssertEqual(ledgerInputTotal(dir), 100,
                       "authority 仍記得已入帳到 200 ⇒ 只計保留窗內的 200→300;若為 300 則已壓縮的段落被重算")
    }

    // MARK: ScanState 遺失但 accounting 權威完好
    //
    // Contract:cursor 遺失導致全表重掃時,既有已入帳歷史不得被重算,而真正的新 growth 必須完整計入。
    func testMarkLossWithoutCompactionMustNotRecountAndMustCountNewGrowth() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let scanURL = dir.appendingPathComponent("scan-state.json")
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay)])
        establish(dir, dbURL)                                   // baseline := 100

        update(dbURL, Row(id: "s1", ti: 300, tu: now))
        try FileManager.default.removeItem(at: scanURL)          // ScanState 遺失
        runRefresh(coord(dir, dbURL))

        let ids = ledger(dir).events.map(\.id).sorted()
        XCTAssertEqual(ids.count, 1, "應為自 anchor(100)接續的單一成長事件,而非自零重發")
        XCTAssertTrue(ids.first?.contains(":1:100,0,0,0,") ?? false,
                      "事件必須自 previous=100 接續(id 已綁完整 operation 座標,見 R3/X2)")
        XCTAssertEqual(ledgerInputTotal(dir), 200, "establishment 之後的真實成長 100→300")
    }

    // MARK: 跨行程
    //
    // Contract:取得 refresh lock 後,cumulative provider 必須自最新 durable authority 導出 delta,
    // 不得沿用 process-local 的陳舊狀態。
    func testCrossProcessMustDeriveFromDurableAuthority() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay)])
        let longLived = coord(dir, dbURL)
        runRefresh(longLived)                                    // establishment,baseline := 100
        XCTAssertEqual(ledgerInputTotal(dir), 0, "前置:establishment 不發事件")

        update(dbURL, Row(id: "s1", ti: 200, tu: now - 2 * Self.msPerDay))
        runRefresh(coord(dir, dbURL))                            // 另一個行程 durable 推進
        XCTAssertEqual(ledgerInputTotal(dir), 100, "前置:第二個行程把 authority 推進到 200")

        update(dbURL, Row(id: "s1", ti: 300, tu: now - Self.msPerDay))
        runRefresh(longLived)   // 同一長駐 instance,記憶體仍停在 100

        XCTAssertEqual(ledgerInputTotal(dir), 200,
                       "入鎖後重讀權威 ⇒ 自 200 導出 100;沿用陳舊記憶體會導出重複 id 而漏計")
    }

    // 註:原 `testSessionIncarnationMustNotInheritBaseline` 已移除 —— 它編碼了「新 incarnation
    // 一律全額計入」這個**錯誤契約**,由 OpenCode50ContractMatrixTests 的 C2/C3 取代
    //(establishment 由 durable complete-census boundary 決定)。

    // MARK: cursor 不得決定權威列是否被檢視
    //
    // Contract:scan cursor 僅為探索最佳化;它不得阻止對「已具權威的 session incarnation」
    // 做 rollback / incarnation 檢查。
    //
    // Scenario:還原一份備份使 counter 與 time_updated 同時倒退 ⇒ 若以 time_updated >= cursor 過濾,
    // 該列本輪不會被看到,epoch 邊界被錯過;等到時間戳超過 cursor 時才看到低於 baseline 的計數,
    // 被當成單純 rollback 直接重錨,還原後真實發生的成長被一併吞掉。
    func testCursorMustNotHideRollback() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let t2 = now - 5 * Self.msPerDay
        let t1 = now - 10 * Self.msPerDay

        makeDb(at: dbURL, [Row(id: "s1", ti: 200, tu: t2)])
        establish(dir, dbURL)                            // baseline := 200,cursor 前進到 t2

        update(dbURL, Row(id: "s1", ti: 120, tu: t1))    // 備份還原:計數與時間戳**同時**倒退
        runRefresh(coord(dir, dbURL))                    // 該列的 tu < cursor —— 仍必須被看到

        update(dbURL, Row(id: "s1", ti: 150, tu: now))   // 還原後真實消耗 30
        runRefresh(coord(dir, dbURL))

        XCTAssertEqual(ledgerInputTotal(dir), 30,
                       "還原建立 epoch 邊界(baseline 120)後,真實新增 30 必須恰好計一次;0 表示被 rollback reset 吞掉")
    }
}
