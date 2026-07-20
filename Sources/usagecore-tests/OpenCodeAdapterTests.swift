import Foundation
import SQLite3
import UsageCore

// MARK: - OpenCode adapter —— 程式化 SQLite fixture(不進 repo 二進位檔)
// R1 雙審測試矩陣:差額/摺疊/增量/回歸+重生長 id/重播低估/cost 歧義與獨立回歸/
// authorizer 誘餌 view/busy fail-soft/schema 漂移 fail-soft/水位線 >= 邊界。

final class OpenCodeAdapterTests: XCTestCase {

    private struct FixtureRow {
        var id: String
        var dir: String = "/Users/t/proj-a"
        var model: String? = #"{"id":"moonshotai/kimi-k3","providerID":"openrouter","variant":"max"}"#
        var cost: Double = 0
        var ti = 0, to = 0, tr = 0, tcr = 0, tcw = 0
        var tu: Int64 = 1_760_000_000_000   // ms
    }

    /// 建 fixture db:包含**額外的內容欄**(title,帶哨兵)與**同庫 credential 表**——
    /// adapter 必須在它們存在下正常運作且永不讀取。
    private func makeDb(_ rows: [FixtureRow], extraSQL: [String] = []) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("octest-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        exec(db, """
        CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, directory TEXT NOT NULL,
          title TEXT, model TEXT, cost REAL DEFAULT 0 NOT NULL,
          tokens_input INTEGER DEFAULT 0 NOT NULL, tokens_output INTEGER DEFAULT 0 NOT NULL,
          tokens_reasoning INTEGER DEFAULT 0 NOT NULL, tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
          tokens_cache_write INTEGER DEFAULT 0 NOT NULL, time_updated INTEGER NOT NULL);
        """)
        exec(db, "CREATE TABLE credential (id TEXT PRIMARY KEY, value TEXT);")
        exec(db, "INSERT INTO credential VALUES ('c1','SECRET-SENTINEL-NEVER-READ');")
        for r in rows { insert(db, r) }
        for sql in extraSQL { exec(db, sql) }
        return url
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
        if let err { sqlite3_free(err) }
    }

    private func insert(_ db: OpaquePointer?, _ r: FixtureRow) {
        let model = r.model.map { "'\($0)'" } ?? "NULL"
        exec(db, """
        INSERT OR REPLACE INTO session VALUES ('\(r.id)','p','\(r.dir)','TITLE-SENTINEL',\(model),
          \(r.cost),\(r.ti),\(r.to),\(r.tr),\(r.tcr),\(r.tcw),\(r.tu));
        """)
    }

    private func update(_ url: URL, _ r: FixtureRow) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        insert(db, r)
        sqlite3_close_v2(db)
    }

    // MARK: 快樂路徑:摺疊、ms 時間戳、model 窄解碼、providerCost、id 形狀

    func testHappyPathFoldsAndEmitsProviderCost() throws {
        let url = makeDb([FixtureRow(id: "s1", cost: 4.8865,
                                     ti: 421_737, to: 42_253, tr: 52_472, tcr: 7_334_870, tcw: 10,
                                     tu: 1_760_000_000_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (result, state) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.events.count, 1)
        let e = result.events[0]
        XCTAssertEqual(e.id, "oc:s1:1:0")
        XCTAssertEqual(e.providerId, "opencode")
        XCTAssertEqual(e.tokens.input, 421_737)
        XCTAssertEqual(e.tokens.output, 42_253 + 52_472, "reasoning 摺入 output")
        XCTAssertEqual(e.tokens.cacheRead, 7_334_870)
        XCTAssertEqual(e.tokens.cacheWriteUnknown, 10, "無 TTL 標示 → unknown 桶,不假冒 5m")
        XCTAssertEqual(e.tokens.cacheWrite5m, 0)
        XCTAssertEqual(e.modelId, "moonshotai/kimi-k3")
        XCTAssertEqual(e.projectName, "proj-a")
        XCTAssertEqual(e.providerCostUSD ?? -1, 4.8865, accuracy: 1e-9)
        XCTAssertEqual(e.timestamp.timeIntervalSince1970, 1_760_000_000, accuracy: 0.001, "毫秒→秒")
        XCTAssertEqual(state.files[url.path]?.offset, 1_760_000_000_000)
    }

    // MARK: 增量:重跑零事件;成長只發差額

    func testIncrementalDeltaOnly() throws {
        let url = makeDb([FixtureRow(id: "s1", cost: 1.0, ti: 100, to: 50, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (r1, s1) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(r1.events.count, 1)
        // 同狀態重跑(>= 水位線重讀同列):零差額 → 零事件、零重複
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 0, "frontier >= 重讀必須是 no-op")
        // 成長 → 只發差額;id 的 from = 前次摺疊總量
        update(url, FixtureRow(id: "s1", cost: 1.5, ti: 160, to: 80, tu: 2_000))
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertEqual(r3.events[0].tokens.input, 60)
        XCTAssertEqual(r3.events[0].tokens.output, 30)
        XCTAssertEqual(r3.events[0].id, "oc:s1:1:150")
        XCTAssertEqual(r3.events[0].providerCostUSD ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: 回歸 → epoch+1、不發事件;重生長越過舊總量 → 新 epoch id 不碰撞

    func testRegressionThenRegrowthNeverCollides() throws {
        let url = makeDb([FixtureRow(id: "s1", ti: 100, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (r1, s1) = try adapter.refreshUsage(state: ScanState())
        let firstId = r1.events[0].id                       // oc:s1:1:0
        update(url, FixtureRow(id: "s1", ti: 20, tu: 2_000))   // 倒退
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 0, "倒退不發事件、不發負值")
        update(url, FixtureRow(id: "s1", ti: 100, tu: 3_000))  // 重生長回同一總量
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertEqual(r3.events[0].id, "oc:s1:2:20", "epoch 消歧 —— 不得與 \(firstId) 同鍵被吞")
        XCTAssertEqual(r3.events[0].tokens.input, 80)
    }

    // MARK: 混合正負(任一類倒退)→ 全類重設、不發事件(G7)

    func testMixedSignClassesResetAll() throws {
        let url = makeDb([FixtureRow(id: "s1", ti: 100, to: 100, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (_, s1) = try adapter.refreshUsage(state: ScanState())
        update(url, FixtureRow(id: "s1", ti: 110, to: 95, tu: 2_000))   // input +10, output −5
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 0, "部分類別倒退 → 不得發出正差額(過度計數)")
        update(url, FixtureRow(id: "s1", ti: 120, to: 95, tu: 3_000))
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertEqual(r3.events[0].tokens.input, 10, "重設後以新基準續算")
    }

    // MARK: 重播(scan-state 寫失敗)→ 同 id → 帳本去重 → 有界低估(C1)

    func testReplayFromStaleStateReusesIdForDedupUndercount() throws {
        let url = makeDb([FixtureRow(id: "s1", ti: 100, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (_, s1) = try adapter.refreshUsage(state: ScanState())
        update(url, FixtureRow(id: "s1", ti: 150, tu: 2_000))
        let (rA, _) = try adapter.refreshUsage(state: s1)      // 狀態寫入「失敗」:沿用 s1
        update(url, FixtureRow(id: "s1", ti: 200, tu: 3_000))
        let (rB, _) = try adapter.refreshUsage(state: s1)      // 重播:更大的差額、同一 from
        XCTAssertEqual(rA.events[0].id, rB.events[0].id,
                       "同 from 鍵 → 帳本 keep-first 去重 → 低估方向(絕不過度計數)")
    }

    // MARK: cost 規則:0 歧義、獨立倒退(C4)

    func testCostZeroWithTokensIsAmbiguousNotFree() throws {
        let url = makeDb([FixtureRow(id: "s1", cost: 0, ti: 500, tu: 1_000)])
        let (r, _) = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
        XCTAssertEqual(r.events.count, 1)
        XCTAssertNil(r.events[0].providerCostUSD, "cost==0 + tokens>0 是缺費率歧義 → 未定價,不是免費")
    }

    func testCostRegressionResetsIndependentlyTokensStillEmit() throws {
        let url = makeDb([FixtureRow(id: "s1", cost: 2.0, ti: 100, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (_, s1) = try adapter.refreshUsage(state: ScanState())
        update(url, FixtureRow(id: "s1", cost: 0.5, ti: 150, tu: 2_000))   // cost 倒退、token 成長
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 1, "token 差額照發")
        XCTAssertNil(r2.events[0].providerCostUSD, "cost 倒退輪不掛 providerCost")
        update(url, FixtureRow(id: "s1", cost: 0.8, ti: 200, tu: 3_000))
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events[0].providerCostUSD ?? -1, 0.3, accuracy: 1e-9, "重設後差額正確")
    }

    // MARK: cost-only 回歸必須立即持久化(R2 grok F1 / codex F3)

    func testCostOnlyRegressionPersistsResetBaseline() throws {
        let url = makeDb([FixtureRow(id: "s1", cost: 2.0, ti: 100, tu: 1_000)])
        let adapter = OpenCodeAdapter(dbURL: url)
        let (_, s1) = try adapter.refreshUsage(state: ScanState())
        // cost-only 倒退(token 不變)
        update(url, FixtureRow(id: "s1", cost: 0.5, ti: 100, tu: 2_000))
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 0)
        // 之後合法增量:0.5 → 0.9(+0.4)+ token 成長 —— 不得再被當成又一次倒退吞掉
        update(url, FixtureRow(id: "s1", cost: 0.9, ti: 150, tu: 3_000))
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertEqual(r3.events[0].providerCostUSD ?? -1, 0.4, accuracy: 1e-9,
                       "cost-only 倒退的重設必須已持久化,合法增量不得流失")
    }

    // MARK: authorizer 誘餌 2:掛在 sqlite_master 上的 view 也必須被拒(R2 codex F5)

    func testAuthorizerDeniesViewOverSqliteMaster() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("octest-master-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, "CREATE VIEW session AS SELECT name AS id, 'd' AS directory, NULL AS model, 0.0 AS cost, 1 AS tokens_input, 1 AS tokens_output, 0 AS tokens_reasoning, 0 AS tokens_cache_read, 0 AS tokens_cache_write, 1000 AS time_updated FROM sqlite_master;")
        sqlite3_close_v2(db)
        do {
            let (r, _) = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            XCTAssertTrue(false, "sqlite_master 誘餌 view 讀到了 \(r.events.count) 筆 —— 內部表也必須 DENY")
        } catch {
            // 預期:授權拒絕 → fail-soft
        }
    }

    // MARK: 負計數器 / NULL 欄位 → 整輪 fail-soft,不得偽造基準(R2 codex F8)

    func testNegativeCountersRejected() {
        var row = FixtureRow(id: "s1", tu: 1_000)
        row.ti = -5
        let url = makeDb([row])
        do {
            _ = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            XCTAssertTrue(false, "負計數器必須整輪拒絕(否則負基準之後偽造正差額)")
        } catch { XCTAssertTrue(error is OpenCodeError) }
    }

    // MARK: 唯讀開啟不得替已 checkpoint 的 db 創建 sidecar(R2 codex F6 實證釘住)

    func testReadOnlyOpenCreatesNoSidecarsOnCheckpointedDb() throws {
        let url = makeDb([FixtureRow(id: "s1", ti: 10, tu: 1_000)])
        // 切到 WAL、寫入、**顯式 checkpoint(TRUNCATE)** 後關閉;殘留 sidecar 一律移除,
        // 模擬「完全 checkpoint、無 sidecar」的合法靜止狀態(實測:close 未必自動清)。
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "INSERT OR REPLACE INTO session VALUES ('s1','p','/Users/t/proj-a','T',NULL,0,20,0,0,0,0,2000);")
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")   // 內容全數落主檔
        sqlite3_close_v2(db)
        let fm = FileManager.default
        try? fm.removeItem(atPath: url.path + "-wal")
        try? fm.removeItem(atPath: url.path + "-shm")
        // 實測釘住(R2 codex F6):sidecar 全缺的 WAL db,唯讀開啟**無法建立讀交易**
        // (readonly 不能創建 -shm)→ fail-soft;無論成敗,**絕不創建** sidecar。
        // (sidecar 由 opencode 下次執行時重建 → 自癒;文件同句揭露。)
        do {
            let (r, _) = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            // 若未來 SQLite 版本允許此狀態的唯讀讀取:資料必須完整
            XCTAssertEqual(r.events.count, 1)
            XCTAssertEqual(r.events[0].tokens.input, 20)
        } catch {
            XCTAssertTrue(error is OpenCodeError, "只允許 fail-soft,不允許其他錯誤型別")
        }
        XCTAssertFalse(fm.fileExists(atPath: url.path + "-wal"), "唯讀掃描不得創建 -wal")
        XCTAssertFalse(fm.fileExists(atPath: url.path + "-shm"), "唯讀掃描不得創建 -shm")
    }

    // MARK: 父目錄拒寫時,任何 sidecar 創建嘗試都物理性失敗 → 只允許 fail-soft(R3 codex F2)

    func testReadOnlyOpenInUnwritableDirectoryFailsSoftOnly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("octest-rodir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = makeDb([FixtureRow(id: "s1", ti: 10, tu: 1_000)])
        let url = dir.appendingPathComponent("opencode.db")
        try FileManager.default.copyItem(at: src, to: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
        sqlite3_close_v2(db)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        // 目錄不可寫 → SQLite 即使想創建 sidecar 也做不到;結果只能是「成功且無創建」
        // 或 OpenCodeError fail-soft —— 絕不得是其他錯誤/崩潰。
        do {
            _ = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
        } catch {
            XCTAssertTrue(error is OpenCodeError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    // MARK: 舊欄位嚴格解碼:型別錯誤的壞列必須整列失敗,不得矽轉 0(R2 codex F7)

    func testLegacyFieldsDecodeStrictly() {
        let wrongType = Data(#"{"input":"oops","output":2,"cacheRead":3,"cacheWrite5m":4,"cacheWrite1h":5}"#.utf8)
        XCTAssertNil(try? AtomicJSON.decoder().decode(TokenBreakdown.self, from: wrongType),
                     "既有鍵型別錯誤 → 整列失敗浮出,不得變成 0")
        let missingOld = Data(#"{"input":1,"output":2}"#.utf8)
        XCTAssertNil(try? AtomicJSON.decoder().decode(TokenBreakdown.self, from: missingOld),
                     "既有鍵缺漏 → 失敗(只有新鍵 cacheWriteUnknown 寬容)")
        let costWrong = Data(#"{"knownUSD":"x","unknownModelTokens":0,"isEstimated":false}"#.utf8)
        XCTAssertNil(try? AtomicJSON.decoder().decode(CostResult.self, from: costWrong))
    }

    // MARK: model JSON 壞值 → modelId nil + parseErrors,事件照發

    func testMalformedModelJSON() throws {
        var row = FixtureRow(id: "s1", ti: 10, tu: 1_000)
        row.model = "not-json"
        let (r, _) = try OpenCodeAdapter(dbURL: makeDb([row])).refreshUsage(state: ScanState())
        XCTAssertEqual(r.events.count, 1)
        XCTAssertNil(r.events[0].modelId)
        XCTAssertEqual(r.parseErrors, 1)
    }

    // MARK: schema 漂移(缺欄)→ throw、狀態不推進、不崩潰

    func testMissingColumnFailsSoft() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("octest-drift-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE session (id TEXT PRIMARY KEY, time_updated INTEGER NOT NULL);")
        sqlite3_close_v2(db)
        do {
            _ = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            XCTAssertTrue(false, "缺欄 schema 必須 throw(fail-soft)")
        } catch {
            XCTAssertTrue(error is OpenCodeError)
        }
    }

    // MARK: authorizer 誘餌:session 是掛在 credential 上的 VIEW → 拒絕(C8)

    func testAuthorizerDeniesDecoyViewOverCredentials() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("octest-decoy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE credential (id TEXT, value TEXT, directory TEXT, model TEXT, cost REAL, tokens_input INT, tokens_output INT, tokens_reasoning INT, tokens_cache_read INT, tokens_cache_write INT, time_updated INT);")
        exec(db, "INSERT INTO credential VALUES ('x','SECRET','d','m',0,1,1,1,1,1,1000);")
        exec(db, "CREATE VIEW session AS SELECT id, directory, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, time_updated FROM credential;")
        sqlite3_close_v2(db)
        do {
            let (r, _) = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            XCTAssertTrue(false, "誘餌 view 讀到了 \(r.events.count) 筆 —— authorizer 必須拒絕底層 credential 讀取")
        } catch {
            // 預期:prepare 因授權拒絕而失敗 → fail-soft
        }
    }

    // MARK: busy(獨占鎖)→ fail-soft、不半批

    func testBusyDatabaseFailsSoft() {
        let url = makeDb([FixtureRow(id: "s1", ti: 10, tu: 1_000)])
        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &locker), SQLITE_OK)
        exec(locker, "BEGIN EXCLUSIVE;")
        defer { exec(locker, "COMMIT;"); sqlite3_close_v2(locker) }
        do {
            _ = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
            XCTAssertTrue(false, "獨占鎖下必須 throw(整輪放棄,不產生半批事件)")
        } catch {
            XCTAssertTrue(error is OpenCodeError)
        }
    }

    // MARK: watcher 白名單:無目錄 roots;只監 db + wal(auth.json 不在觸發集)

    func testWatchFilesExactAndNoDirectoryRoots() {
        let url = makeDb([])
        let adapter = OpenCodeAdapter(dbURL: url)
        XCTAssertTrue(adapter.roots.isEmpty, "目錄 roots 會被 coordinator 整棵當 trigger —— 必須為空")
        XCTAssertEqual(adapter.watchFiles.map(\.path), [url.path, url.path + "-wal"])
    }

    // MARK: 零用量 session → 不發事件

    func testZeroTokenSessionEmitsNothing() throws {
        let url = makeDb([FixtureRow(id: "s1", tu: 1_000)])
        let (r, _) = try OpenCodeAdapter(dbURL: url).refreshUsage(state: ScanState())
        XCTAssertEqual(r.events.count, 0)
    }

    // MARK: 自訂 db 位置 → disclosure 歸類 custom(fail-closed)

    func testCustomDbLocationDisclosesCustom() {
        let adapter = OpenCodeAdapter(dbURL: makeDb([]))
        if case .custom = adapter.detectAvailability().disclosure {} else {
            XCTAssertTrue(false, "非內建根必須揭露為 custom")
        }
    }

    // MARK: 新模型欄位的序列化相容(帳本回讀)

    func testNewFieldsCodableRoundTripAndTolerantDecode() throws {
        // 舊帳本列(無 cacheWriteUnknown / providerCostUSD)照常解碼
        let old = Data(#"{"id":"x","providerId":"opencode","timestamp":"2026-07-19T00:00:00Z","tokens":{"input":1,"output":2,"cacheRead":3,"cacheWrite5m":4,"cacheWrite1h":5},"sourceKind":"k"}"#.utf8)
        let decoded = try AtomicJSON.decoder().decode(UsageEvent.self, from: old)
        XCTAssertEqual(decoded.tokens.cacheWriteUnknown, 0)
        XCTAssertNil(decoded.providerCostUSD)
        XCTAssertEqual(decoded.tokens.total, 15)
        // 新欄位 round-trip
        let e = UsageEvent(id: "y", providerId: "opencode", timestamp: Date(),
                           tokens: TokenBreakdown(input: 1, cacheWriteUnknown: 7),
                           sourceKind: "k", providerCostUSD: 1.25)
        let redecoded = try AtomicJSON.decoder().decode(UsageEvent.self,
                                                        from: AtomicJSON.encoder().encode(e))
        XCTAssertEqual(redecoded.tokens.cacheWriteUnknown, 7)
        XCTAssertEqual(redecoded.tokens.cacheWrite, 7)
        XCTAssertEqual(redecoded.providerCostUSD ?? -1, 1.25, accuracy: 1e-9)
        // 舊 CostResult JSON 容忍
        let oldCost = try AtomicJSON.decoder().decode(CostResult.self,
            from: Data(#"{"knownUSD":1.5,"unknownModelTokens":0,"isEstimated":true}"#.utf8))
        XCTAssertEqual(oldCost.providerReportedUSD, 0, accuracy: 1e-9)
    }

    // MARK: 計價優先序:provider 回報成本 → 不雙重計費、標 estimated + 出處

    func testPricingPrecedenceProviderReportedCost() {
        let pricing = PricingRegistry.loadDefault(overridesURL: URL(fileURLWithPath: "/nonexistent"))
        let withCost = UsageEvent(id: "a", providerId: "opencode", modelId: "moonshotai/kimi-k3",
                                  timestamp: Date(), tokens: TokenBreakdown(input: 1000),
                                  sourceKind: "k", providerCostUSD: 0.42)
        let c1 = pricing.cost(of: withCost)
        XCTAssertEqual(c1.knownUSD, 0.42, accuracy: 1e-9)
        XCTAssertEqual(c1.providerReportedUSD, 0.42, accuracy: 1e-9)
        XCTAssertEqual(c1.unknownModelTokens, 0, "有 provider 成本 → 不是 unknown model")
        XCTAssertTrue(c1.isEstimated, "models.dev 費率是估算,非發票")
        // 無 provider 成本 + 無價目 → 誠實 unknown(行為不變)
        let without = UsageEvent(id: "b", providerId: "opencode", modelId: "moonshotai/kimi-k3",
                                 timestamp: Date(), tokens: TokenBreakdown(input: 1000), sourceKind: "k")
        XCTAssertEqual(pricing.cost(of: without).unknownModelTokens, 1000)
        // 無效值(0 / 負 / NaN)→ 一律走 registry 路徑
        for bad in [0.0, -1.0, Double.nan] {
            let e = UsageEvent(id: "c", providerId: "opencode", modelId: "m", timestamp: Date(),
                               tokens: TokenBreakdown(input: 10), sourceKind: "k", providerCostUSD: bad)
            XCTAssertEqual(pricing.cost(of: e).providerReportedUSD, 0, accuracy: 1e-9)
        }
    }
}
