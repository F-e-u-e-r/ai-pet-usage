import Foundation
import SQLite3
@testable import UsageCore

// MARK: - #50 owner-approved contract matrix
//
// 本檔是 #50 的 oracle。它取代先前兩條編碼了**錯誤契約**的測試
//(舊假設:authority 已載入時,任何新 incarnation 一律全額計入)。
//
// 已裁定的語義:
//   R1  establishment 由 durable complete-census boundary 決定,不由 time_created 看起來新不新決定
//   R2  re-baseline 先 settle 所有 pending;保留未觀測到的既有 anchor
//   R3  event identity 必須綁 session incarnation
//   R4  authority 語義驗證含 pending event payload 與 overflow-safe 算術
//   R5  rename 之後的 dir-sync 失敗 = outcome-unknown
//   R6  provider-reported cost 與 registry estimate 互斥

final class OpenCode50ContractMatrixTests: XCTestCase {

    private struct Row {
        var id: String
        var ti: Int
        var tu: Int64
        var tc: Int64
        var cost: Double = 0
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
          '{"id":"m/x"}',\(r.cost),\(r.ti),0,0,0,0,\(r.tc),\(r.tu));
        """)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
        if let err { sqlite3_free(err) }
    }

    private func coord(_ dir: URL, _ dbURL: URL, anchor: DurabilityOps? = nil,
                       ledgerOps: DurabilityOps? = nil) -> UsageCoordinator {
        var s = CoreSettings()
        s.enabledProviders = ["opencode"]
        return UsageCoordinator(dataDir: dir, settings: s, adapters: [OpenCodeAdapter(dbURL: dbURL)],
                                limitsDurabilityOps: .production,
                                anchorDurabilityOps: anchor, ledgerDurabilityOps: ledgerOps)
    }

    @discardableResult
    private func runRefresh(_ c: UsageCoordinator) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await c.refresh(); sem.signal() }
        sem.wait()
        return out!
    }

    private func rebaseline(_ c: UsageCoordinator) -> UsageCoordinator.RebaselineOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: UsageCoordinator.RebaselineOutcome?
        Task { out = await c.rebaselineCumulative(providerId: "opencode"); sem.signal() }
        sem.wait()
        return out!
    }

    private func ledger(_ dir: URL) -> UsageLedger {
        UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
    }
    private func inputTotal(_ dir: URL) -> Int {
        ledger(dir).events.filter { $0.providerId == "opencode" }.reduce(0) { $0 + $1.tokens.input }
    }
    private func authorityURL(_ dir: URL) -> URL { dir.appendingPathComponent("cumulative-anchors.json") }
    private func authority(_ dir: URL) -> CumulativeAuthority? {
        AtomicJSON.read(CumulativeAuthority.self, from: authorityURL(dir))
    }
    private func anchors(_ dir: URL) -> [String: CumulativeAnchor] {
        authority(dir)?.providers["opencode"] ?? [:]
    }
    private func key(_ sid: String, _ tc: Int64) -> String {
        IncarnationKey(sessionId: sid, timeCreatedMs: tc).encoded
    }

    private static let msPerDay: Int64 = 86_400_000

    // MARK: C1 —— provider 首次建立:既有總量 zero-delta,不回填
    func testC1FirstEverEstablishmentIsZeroDelta() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 1_000_000, tu: now - Self.msPerDay, tc: now - 200 * Self.msPerDay)])

        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 0, "C1:首次建立不得回填既有總量")
        XCTAssertEqual(anchors(dir)[key("s1", now - 200 * Self.msPerDay)]?.accountedThrough.input,
                       1_000_000, "C1:但必須成為 baseline")
        XCTAssertNotNil(authority(dir)?.lastCompleteCensusMs["opencode"],
                        "C1:完整成功的 census 必須留下 durable boundary")
    }

    // MARK: C2 —— 觀測邊界之後才建立的 incarnation:首窗累計量必須計入
    func testC2IncarnationCreatedAfterCensusBoundaryCountsFirstWindow() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 5 * Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))                       // 建立 + 記錄 census boundary
        let boundary = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(boundary > 0, "C2 前置:boundary 已記錄")

        // 新 session,建立時間在 boundary 之後 ⇒ 其 60 確定發生於可信觀測期內。
        update(db, Row(id: "s2", ti: 60, tu: now, tc: boundary + 1_000))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 60,
                       "C2:boundary 之後建立的 incarnation,其首窗累計量必須計入")
    }

    // MARK: C3 —— 建立時間早於邊界卻沒有 anchor:歧義,必須 fail closed
    func testC3IncarnationOlderThanBoundaryWithoutAnchorFailsClosed() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 5 * Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))
        let boundary = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0

        // 一個「本應早已可見」卻從未有 anchor 的 incarnation 突然出現。
        update(db, Row(id: "ghost", ti: 500, tu: now, tc: boundary - 10 * Self.msPerDay))
        let out = runRefresh(coord(dir, db))

        XCTAssertEqual(inputTotal(dir), 0, "C3:不得自零回填 500")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-baseline") },
                      "C3:歧義必須 fail closed 並指向 explicit re-baseline")
    }

    // MARK: C4 —— 同 sessionId、不同 timeCreated ⇒ 事件 id 必須獨立
    func testC4EventIdsAreIndependentAcrossIncarnations() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "seed", ti: 5, tu: now - 10 * Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))
        let boundary = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0

        update(db, Row(id: "s1", ti: 40, tu: now - 2 * Self.msPerDay, tc: boundary + 1_000))
        runRefresh(coord(dir, db))
        update(db, Row(id: "s1", ti: 70, tu: now, tc: boundary + 2_000))   // 另一個 incarnation
        runRefresh(coord(dir, db))

        let ids = ledger(dir).events.filter { $0.providerId == "opencode" }.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "C4:兩個 incarnation 的事件 id 不得相同")
        XCTAssertEqual(inputTotal(dir), 110, "C4:40 + 70 皆須計入,不得被 dedup 吞掉")
    }

    // MARK: C5 —— re-baseline 遇未完成 pending:先 settle 或整體失敗,絕不丟棄
    func testC5RebaselineNeverDiscardsOutstandingPending() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))

        update(db, Row(id: "s1", ti: 160, tu: now - Self.msPerDay, tc: tc))
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        runRefresh(coord(dir, db, ledgerOps: rec.ops))     // 造出 durable pending、帳本未寫
        XCTAssertNotNil(anchors(dir)[key("s1", tc)]?.pending, "C5 前置:pending durable")

        _ = rebaseline(coord(dir, db))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 60,
                       "C5:未落盤的 pending 用量絕不得因 re-baseline 而消失")
    }

    // MARK: C6 —— re-baseline 必須保留當下未觀測到的既有 anchor
    func testC6RebaselinePreservesUnobservedAnchors() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tcA = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tcA)])
        runRefresh(coord(dir, db))
        let boundary = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0

        // s1 暫時自來源消失,期間執行 re-baseline。
        var d: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &d), SQLITE_OK)
        exec(d, "DELETE FROM session WHERE id = 's1';")
        sqlite3_close_v2(d)
        update(db, Row(id: "s2", ti: 10, tu: now, tc: boundary + 1_000))
        _ = rebaseline(coord(dir, db))

        XCTAssertNotNil(anchors(dir)[key("s1", tcA)],
                        "C6:暫時缺席不等於刪除 —— 既有 anchor 必須原樣保留")
    }

    // MARK: C7 —— pending event 的 token 欄位溢位:必須 reject,不得 trap
    func testC7OverflowingPendingTokensRejectAuthorityWithoutTrapping() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc)])

        let prev = AnchorCounters(input: 100)
        let target = AnchorCounters(input: 160)
        var tokens = TokenBreakdown(input: 60)
        tokens.cacheWrite5m = Int.max
        tokens.cacheWrite1h = 1                       // 相加即溢位
        let ev = UsageEvent(id: "oc2:x", providerId: "opencode", timestamp: Date(),
                            tokens: tokens, sourceKind: "opencode-session")
        let store = CumulativeAnchorStore(fileURL: authorityURL(dir), durabilityOps: .production)
        try store.saveDurably(CumulativeAuthority(providers: ["opencode": [
            key("s1", tc): CumulativeAnchor(epoch: 1, accountedThrough: prev,
                pending: PendingReconciliation(event: ev, previous: prev, target: target, epoch: 1))
        ]]))

        // 必須是 rejected,而不是行程崩潰。
        if case .rejected = store.load() {} else {
            XCTAssertTrue(false, "C7:溢位的 pending token 必須使整份 authority 被 reject")
        }
    }

    // MARK: C8 —— rename 之後的 dir-sync 失敗 = outcome-unknown
    func testC8PostRenameDirSyncFailureIsOutcomeUnknown() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))

        let rec = DurabilityOpsRecorder()
        rec.failSyncDirectoryFrom = 2                 // #1 = X1 confirm 成功;#2 = save 的 dir-sync 失敗
        let outcome = rebaseline(coord(dir, db, anchor: rec.ops))
        if case .outcomeUnknown = outcome {} else {
            XCTAssertTrue(false, "C8:rename 後的 dir-sync 失敗不得回報成 failed(未變更)")
        }
    }

    // MARK: C9 —— provider-reported cost 與 registry estimate 互斥
    func testC9ExplicitProviderCostSuppressesRegistryFallback() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc, cost: 1.0)])
        runRefresh(coord(dir, db))

        // 先來一輪「有 token 成長但 cost 未變」⇒ provider cost 對本輪不可得。
        update(db, Row(id: "s1", ti: 200, tu: now - 2 * Self.msPerDay, tc: tc, cost: 1.0))
        runRefresh(coord(dir, db))
        // 再來一輪 cost-only 上升。
        update(db, Row(id: "s1", ti: 200, tu: now - Self.msPerDay, tc: tc, cost: 3.0))
        runRefresh(coord(dir, db))
        // 最後一輪 token 成長。
        update(db, Row(id: "s1", ti: 260, tu: now, tc: tc, cost: 3.5))
        runRefresh(coord(dir, db))

        let evs = ledger(dir).events.filter { $0.providerId == "opencode" }
            .sorted { $0.timestamp < $1.timestamp }

        // (a) cost-only 的 $2.0 自成一筆(零 token ⇒ registry 估價為 0,不可能重複計價)。
        let costOnly = evs.filter { $0.tokens.total == 0 }
        XCTAssertEqual(costOnly.count, 1, "C9:cost-only 變化必須自成一筆事件")
        XCTAssertEqual(costOnly.first?.providerCostUSD ?? -1, 2.0, accuracy: 1e-6,
                       "C9:cost-only 事件應帶其自身的 provider cost")

        // (b) **關鍵**:最後一筆帶 token 的事件只能帶「該輪自己的」cost delta(0.5),
        //     不得把先前歧義輪累積的成本一併掛上 —— 那些 token 已由 registry 估價,
        //     再掛 provider cost 就是同一批 token 被計價兩次。
        let lastTokenEvent = evs.last { $0.tokens.total > 0 }
        XCTAssertEqual(lastTokenEvent?.providerCostUSD ?? -1, 0.5, accuracy: 1e-6,
                       "C9:provider cost 不得跨輪累積(2.5 表示已與 registry estimate 重複計價)")

        // (c) provider cost 與 registry estimate 互斥:帶 provider cost 者由其決定價格,
        //     未帶者才走 registry —— 同一筆事件永不同時採用兩者。
        for e in evs where e.providerCostUSD != nil {
            XCTAssertTrue(e.providerCostUSD! > 0, "C9:providerCostUSD 非 nil 時必須為正值(0 是歧義,應為 nil)")
        }
    }
    // MARK: C5b —— pending 無法 settle 時,re-baseline 必須整體失敗且不動 authority
    //
    // 契約另一半:「若某 pending 因 ledger/store error 無法完成 ⇒ re-baseline FAILS,
    // authority unchanged, no pending discarded」。C5 覆蓋可 settle 的一支,本條覆蓋不可 settle 的一支。
    func testC5bRebaselineFailsWhenPendingCannotSettle() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))

        update(db, Row(id: "s1", ti: 160, tu: now - Self.msPerDay, tc: tc))
        let failLedger = DurabilityOpsRecorder(); failLedger.failSyncFile = true
        runRefresh(coord(dir, db, ledgerOps: failLedger.ops))   // 造出 durable pending
        let before = anchors(dir)
        XCTAssertNotNil(before[key("s1", tc)]?.pending, "C5b 前置:pending durable")

        // re-baseline 期間帳本仍不可寫 ⇒ 該 pending 無法 settle。
        let outcome = rebaseline(coord(dir, db, ledgerOps: failLedger.ops))
        guard case .failed(let why) = outcome else {
            XCTAssertTrue(false, "C5b:pending 無法 settle 時 re-baseline 必須失敗")
            return
        }
        XCTAssertTrue(why.contains("outstanding reconciliation"),
                      "C5b:失敗原因必須指出是未完成的 reconciliation,而非其他")
        XCTAssertEqual(anchors(dir), before,
                       "C5b:authority 必須逐欄不變,pending 不得被丟棄")
    }
    // MARK: grok r2 F1 重現 —— 首窗為零的 post-boundary incarnation 不會取得 anchor
    //
    // 契約 R1(b):boundary 之後建立的 incarnation,其首窗累計量應計入。但若首次觀測時
    // 該 session 的計數器仍為 0,census 不產生任何 proposal ⇒ 不建立 anchor。
    // 待 boundary 推進到它之後,它就變成 R1(c) 的「本應早已可見卻無權威」⇒ fail closed,
    // 其後真實發生的用量被永久丟棄。
    func testReproGrokR2F1ZeroFirstWindowIncarnationLosesAnchor() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 10 * Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))
        let b1 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b1 > 0, "前置:boundary 已記錄")

        // boundary 之後建立的新 session,但首次觀測時計數器仍為 0。
        // tc 必須落在 b1 與下一輪 boundary 之間 —— 兩輪 refresh 只隔數毫秒,故取 +1ms。
        update(db, Row(id: "s2", ti: 0, tu: now - 5 * Self.msPerDay, tc: b1 + 1))
        runRefresh(coord(dir, db))       // 本輪完成 ⇒ boundary 推進到 s2.timeCreated 之後
        let b2 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b2 > b1 + 1,
                      "前置:boundary 必須已越過 s2 的 timeCreated,否則本測試無法檢驗 F1")

        // s2 之後真的用了 50。
        update(db, Row(id: "s2", ti: 50, tu: now, tc: b1 + 1))
        let out = runRefresh(coord(dir, db))

        XCTAssertEqual(inputTotal(dir), 50,
                       "F1:boundary 之後建立的 session 其真實用量必須被計入,不得因首窗為零而失去 anchor")
        XCTAssertFalse(out.dashboard.dataQuality.contains { $0.contains("re-baseline") },
                       "F1:這不是歧義情境 —— 它建立於觀測期內,不應 fail closed")
    }

    // MARK: grok r2 F1 反腿 —— 零計數多輪後 anchor 仍在,之後的成長恰好計一次
    //
    // owner 指定的 regression 形狀:new post-boundary incarnation + zero counters for
    // N refreshes → anchor persists throughout → later 50 growth counts exactly once。
    func testF1ZeroWindowAnchorPersistsAcrossRefreshesThenCountsExactlyOnce() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 10 * Self.msPerDay, tc: now - 100 * Self.msPerDay)])
        runRefresh(coord(dir, db))
        let b1 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b1 > 0, "前置:boundary 已記錄")

        let tc2 = b1 + 1
        update(db, Row(id: "s2", ti: 0, tu: now - 5 * Self.msPerDay, tc: tc2))
        for i in 1...3 {
            runRefresh(coord(dir, db))
            XCTAssertNotNil(anchors(dir)[key("s2", tc2)],
                            "F1 反腿:第 \(i) 輪零計數 refresh 後 anchor 必須仍在")
            XCTAssertEqual(anchors(dir)[key("s2", tc2)]?.accountedThrough.input ?? -1, 0,
                           "F1 反腿:零計數 anchor 的 baseline 必須為 0,不得虛增")
        }
        let bN = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(bN > tc2, "前置:boundary 必須已越過 s2 的 timeCreated(F1 的觸發前提)")

        update(db, Row(id: "s2", ti: 50, tu: now, tc: tc2))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 50, "F1 反腿:s2 的 50 必須恰好計一次(s1 為 zero-delta 建立)")
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 50, "F1 反腿:重複 refresh 不得重複入帳")
    }

    // MARK: grok r2 F6(b)—— R6 互斥必須驗到 consumer 的 CostResult,不只 adapter 欄位
    //
    // registry 對 fixture 的 model id("m/x")給明確非零價;三案分別證明:
    //   (i)  token + provider cost:final == provider cost(registry 價存在也不得疊加)
    //   (ii) cost-only 事件:final == 該筆 provider cost
    //   (iii) provider cost 不可得的 token 事件:registry estimate 生效(fallback 仍活著)
    func testR6CostPrecedenceReachesConsumerCostResult() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc, cost: 1.0)])
        runRefresh(coord(dir, db))   // zero-delta 建立,無事件

        // (iii) token 成長、cost 未變 ⇒ 該輪 provider cost 不可得
        update(db, Row(id: "s1", ti: 1_000_100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 1.0))
        runRefresh(coord(dir, db))
        // (ii) cost-only 上升 2.0
        update(db, Row(id: "s1", ti: 1_000_100, tu: now - Self.msPerDay, tc: tc, cost: 3.0))
        runRefresh(coord(dir, db))
        // (i) token 成長 + cost 上升 0.5
        update(db, Row(id: "s1", ti: 2_000_100, tu: now, tc: tc, cost: 3.5))
        runRefresh(coord(dir, db))

        let registry = PricingRegistry(entries: [ModelPrice(
            providerId: "opencode", modelId: "m/x", displayName: "fixture",
            inputPerMillion: 10.0, outputPerMillion: 10.0,
            effectiveFrom: "2026-01-01", source: "test")])
        let evs = ledger(dir).events.filter { $0.providerId == "opencode" }
            .sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(evs.count, 3, "前置:三輪各自成一筆事件")
        guard evs.count == 3 else { return }   // 斷言失敗時不得讓下標把整個 runner 帶崩

        // (iii) 無 provider cost 的 1,000,000 input @ $10/M ⇒ registry estimate $10
        XCTAssertNil(evs[0].providerCostUSD, "前置(iii):provider cost 不可得")
        let cIII = registry.cost(of: evs[0])
        XCTAssertEqual(cIII.knownUSD, 10.0, accuracy: 1e-9,
                       "R6(iii):無 provider cost 時 registry estimate 必須生效")
        XCTAssertEqual(cIII.providerReportedUSD, 0.0, accuracy: 1e-12,
                       "R6(iii):不得虛報 provider 出處")

        // (ii) cost-only $2.0、零 token ⇒ final == 2.0
        XCTAssertEqual(evs[1].tokens.total, 0, "前置(ii):cost-only 事件零 token")
        let cII = registry.cost(of: evs[1])
        XCTAssertEqual(cII.knownUSD, 2.0, accuracy: 1e-9,
                       "R6(ii):cost-only 事件的 final cost 必須恰為 provider cost 2.0")

        // (i) 1,000,000 tokens + provider cost 0.5:registry 疊加會是 10.5 ⇒ 必須恰為 0.5
        XCTAssertEqual(evs[2].providerCostUSD ?? -1, 0.5, accuracy: 1e-6, "前置(i):provider cost 0.5")
        let cI = registry.cost(of: evs[2])
        XCTAssertEqual(cI.knownUSD, 0.5, accuracy: 1e-9,
                       "R6(i):provider cost 存在時 final == provider cost,registry estimate 不得疊加")
        XCTAssertEqual(cI.providerReportedUSD, 0.5, accuracy: 1e-9, "R6(i):出處必須標 provider")
        XCTAssertEqual(cI.unknownModelTokens, 0, "R6(i):provider-cost 事件不得同時標 unknown-model")
    }

    // MARK: grok r2 F4 —— census 對演進域已滿的 epoch fail closed,絕不 trap
    //
    // validator 允許 epoch == Int.max - 1 存在,但它已不可演進;倒退迫使 census 走
    // epoch+1 時必須 throw EpochBoundExceeded(整 provider fail closed),而非 trap、
    // 亦不得寫出下次 load 必被 reject 的 Int.max。establishAll 同一律。
    func testF4EpochAtAdvanceBoundFailsClosedWithoutTrapping() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 10, tu: now, tc: tc)])
        let adapter = OpenCodeAdapter(dbURL: db)
        let ik = IncarnationKey(sessionId: "s1", timeCreatedMs: tc)
        let anchors = [ik: CumulativeAnchor(epoch: Int.max - 1,
                                            accountedThrough: AnchorCounters(input: 20))]

        do {
            _ = try adapter.censusCumulative(anchors: anchors, scanState: ScanState(),
                                             boundaryMs: nil, establishAll: false)
            XCTAssertTrue(false, "F4:計數倒退 + epoch 演進域已滿必須 throw,不得靜默成功")
        } catch {
            XCTAssertTrue(error is EpochBoundExceeded,
                          "F4:必須是 EpochBoundExceeded,而非其他錯誤:\(error)")
        }
        do {
            _ = try adapter.censusCumulative(anchors: anchors, scanState: ScanState(),
                                             boundaryMs: nil, establishAll: true)
            XCTAssertTrue(false, "F4:establishAll 在演進域已滿時同樣必須 throw")
        } catch {
            XCTAssertTrue(error is EpochBoundExceeded,
                          "F4(establishAll):必須是 EpochBoundExceeded:\(error)")
        }
    }

    // MARK: grok r2 F2 —— outcome-unknown 貫穿 refresh:halt → reconcile → 恰好一次恢復
    //
    // R5 的 outcome-unknown 不是 CLI 特例:background refresh 遇到它必須
    //   (輪 2)中止該 provider 的 accounting pass、loud、旗標失效 in-memory authority;
    //   (輪 3)reconcile 未成前完全不做 accounting(census/saveAnchors 皆不得嘗試);
    //   (輪 4)confirm 成功後才恢復 —— 且中斷輪的用量經 P3 pending replay 恰好入帳一次。
    func testF2RefreshOutcomeUnknownHaltsAccountingUntilReconciledThenCountsOnce() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        let rec = DurabilityOpsRecorder()
        let c = coord(dir, db, anchor: rec.ops)   // 同一 coordinator 跨輪(旗標是 in-memory 語義)

        runRefresh(c)                             // 輪 1:正常建立(zero-delta)
        XCTAssertEqual(inputTotal(dir), 0, "前置:輪 1 zero-delta 建立,無事件")

        update(db, Row(id: "s1", ti: 150, tu: now - 2 * Self.msPerDay, tc: tc))
        // X1 之後,載入的 authority 會先做一次 durability confirm(dir barrier)——
        // 本測試要打的是「confirm 成功、其後 staged save 的 dir-sync 失敗」的 R5 情境。
        let dirSyncsSoFar = rec.calls.filter { $0 == "syncDirectory" }.count
        rec.failSyncDirectoryFrom = dirSyncsSoFar + 2   // +1 = X1 confirm 成功;+2 = staged save 失敗
        let out2 = runRefresh(c)                  // 輪 2:staged save 的 dir-sync 失敗 ⇒ outcome-unknown
        XCTAssertTrue(out2.dashboard.dataQuality.contains { $0.contains("outcome unknown") },
                      "F2 輪 2:outcome-unknown 必須 loud(非一般錯誤字串)")
        XCTAssertEqual(inputTotal(dir), 0, "F2 輪 2:accounting pass 已中止,ledger 不得有新事件")

        let callsBeforeRound3 = rec.calls.count
        let out3 = runRefresh(c)                  // 輪 3:sync 仍失敗 ⇒ reconcile 不成,accounting 全停
        XCTAssertTrue(out3.dashboard.dataQuality.contains { $0.contains("reconciled") },
                      "F2 輪 3:必須指出 accounting 因待 reconcile 而暫停")
        let round3Calls = Array(rec.calls.dropFirst(callsBeforeRound3))
        XCTAssertEqual(round3Calls, ["syncDirectory"],
                       "F2 輪 3:只允許 reconcile 的 confirm 嘗試 —— 不得有任何 saveAnchors 動作(syncFile/rename):\(round3Calls)")
        XCTAssertEqual(inputTotal(dir), 0, "F2 輪 3:reconcile 未成前不得入帳")

        rec.failSyncDirectoryFrom = nil
        let out4 = runRefresh(c)                  // 輪 4:confirm 成功 → 恢復 → pending replay 恰好一次
        XCTAssertEqual(inputTotal(dir), 50, "F2 輪 4:中斷輪的 50 必須恰好入帳一次(P3 replay)")
        XCTAssertFalse(out4.dashboard.dataQuality.contains { $0.contains("outcome unknown") || $0.contains("reconciled") },
                       "F2 輪 4:恢復後不得再殘留 outcome-unknown / reconcile 訊息")

        runRefresh(c)                             // 輪 5:冪等
        XCTAssertEqual(inputTotal(dir), 50, "F2 輪 5:重複 refresh 不得重複入帳")
    }

    // MARK: grok r2 F5 —— re-baseline 必須留下 census boundary,其後新 session 計首窗
    func testF5RebaselineAdvancesBoundarySoLaterNewSessionsCountFirstWindow() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: now - 100 * Self.msPerDay)])

        guard case .ok = rebaseline(coord(dir, db)) else {
            XCTAssertTrue(false, "前置:re-baseline 必須成功")
            return
        }
        let b = authority(dir)?.lastCompleteCensusMs["opencode"]
        XCTAssertNotNil(b, "F5:成功的 re-baseline 必須留下 durable census boundary")
        XCTAssertTrue((b ?? 0) > 0, "F5:boundary 必須為正的來源時間")
        XCTAssertEqual(inputTotal(dir), 0, "前置:re-baseline 是 zero-delta,不發事件")

        // boundary 之後建立的新 session:首窗必須計入(R1(b)),不得 zero-delta、更不得歧義。
        update(db, Row(id: "s2", ti: 70, tu: now, tc: (b ?? 0) + 1))
        let out = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 70, "F5:re-baseline 後新建立 session 的首窗累計量必須計入")
        XCTAssertFalse(out.dashboard.dataQuality.contains { $0.contains("re-baseline required") },
                       "F5:這不是歧義情境,不得要求再次 re-baseline")
    }

    // MARK: grok r2 F5(單調)—— boundary 是高水位,任何成功寫入都不得使其倒退
    func testF5BoundaryNeverRegressesOnLaterCensus() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))
        let b1 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b1 > 0, "前置:boundary 已記錄")

        // 手寫一個「未來」boundary(digest 重算,合法載入)—— 模擬他方進程已推進更遠。
        let future = b1 + Self.msPerDay
        guard var a = authority(dir) else { XCTAssertTrue(false, "前置:authority 可讀"); return }
        a.lastCompleteCensusMs["opencode"] = future
        a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
        try AtomicJSON.write(a, to: authorityURL(dir))

        update(db, Row(id: "s1", ti: 160, tu: now, tc: tc))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 60, "前置:成長照常入帳(60)")
        XCTAssertEqual(authority(dir)?.lastCompleteCensusMs["opencode"], future,
                       "F5 單調:本輪完成時刻早於既有 boundary ⇒ boundary 必須保持,不得倒退")
    }

    private func execRaw(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK, "reopen fixture db")
        defer { sqlite3_close_v2(db) }
        exec(db, sql)
    }

    // MARK: grok r3 X1 —— fresh process:authority durability confirm happens-before 任何 ledger append
    //
    // owner contract:每個 process 對載入的 authority,在第一次 correctness-affecting 使用前,
    // 必須對 exact loaded authority 建立 durability confirmation;confirmation 失敗 ⇒ 零 append、
    // 零 accounting/cursor 推進。ordering 由「第一次 anchor barrier 當下 ledger 行數」直接證明,
    // 不依 final total(dedup 可能遮 ordering regression)。
    func testX1FreshProcessConfirmsAuthorityDurabilityBeforeAnyLedgerAppend() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        let rec1 = DurabilityOpsRecorder()
        let c1 = coord(dir, db, anchor: rec1.ops)
        runRefresh(c1)                                        // process A:正常建立
        update(db, Row(id: "s1", ti: 150, tu: now - 2 * Self.msPerDay, tc: tc))
        let dirSyncs = rec1.calls.filter { $0 == "syncDirectory" }.count
        rec1.failSyncDirectoryFrom = dirSyncs + 2             // confirm 成功、staged save 的 dir-sync 失敗
        runRefresh(c1)                                        // A:outcome-unknown;pending 已落盤;A 結束
        XCTAssertNotNil(anchors(dir)[key("s1", tc)]?.pending, "前置:pending 已在磁碟")
        XCTAssertEqual(inputTotal(dir), 0, "前置:ledger 尚無 replay 事件")

        // process B(fresh;storage 仍壞):confirmation 失敗 ⇒ ledger 一個 byte 都不能動。
        let rec2 = DurabilityOpsRecorder()
        rec2.failSyncDirectoryFrom = 1
        let outBad = runRefresh(coord(dir, db, anchor: rec2.ops))
        XCTAssertEqual(inputTotal(dir), 0,
                       "X1:confirmation 失敗 ⇒ fresh process 不得 append(pending replay 也不行)")
        XCTAssertTrue(outBad.dashboard.dataQuality.contains { $0.contains("durability unconfirmed") },
                      "X1:必須 loud")
        XCTAssertNotNil(anchors(dir)[key("s1", tc)]?.pending, "X1:pending 保持,不得半處理")

        // process B 的 rebaseline 嘗試同樣必須先 confirm —— settle(可能 append)是
        // correctness-affecting;durability 未確認 ⇒ .failed 且 ledger/pending 原封不動。
        let rec2b = DurabilityOpsRecorder()
        rec2b.failSyncDirectoryFrom = 1
        let rbBad = rebaseline(coord(dir, db, anchor: rec2b.ops))
        if case .failed = rbBad {} else {
            XCTAssertTrue(false, "X1:durability 未確認的 re-baseline 必須 .failed,不得繼續 settle")
        }
        XCTAssertEqual(inputTotal(dir), 0, "X1:re-baseline 的 settle 也不得在 confirm 前 append")
        XCTAssertNotNil(anchors(dir)[key("s1", tc)]?.pending, "X1:pending 原封不動")

        // process C(fresh;storage 恢復):第一次 anchor barrier(= X1 confirm)當下 ledger 必須仍空。
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        var ledgerLinesAtFirstBarrier: Int? = nil
        let rec3 = DurabilityOpsRecorder()
        let base = rec3.ops
        let probeOps = DurabilityOps(
            syncFile: { fd in
                if ledgerLinesAtFirstBarrier == nil {
                    let text = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
                    ledgerLinesAtFirstBarrier = text.split(separator: "\n").count
                }
                return base.syncFile(fd)
            },
            statFile: base.statFile,
            renameFile: base.renameFile,
            syncDirectory: base.syncDirectory)
        runRefresh(coord(dir, db, anchor: probeOps))
        XCTAssertEqual(inputTotal(dir), 50, "X1:恢復後 pending replay 恰好一次")
        XCTAssertEqual(ledgerLinesAtFirstBarrier, 0,
                       "X1 ordering:第一次 authority barrier(confirm)必須發生在任何 ledger append 之前")
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 50, "X1:冪等")
    }

    // MARK: grok r3 X2 —— 連續 cost-only 變化:各自成 event、各自入帳
    func testX2ConsecutiveCostOnlyChangesEachCountExactlyOnce() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc, cost: 1.0)])
        runRefresh(coord(dir, db))                            // zero-delta 建立

        update(db, Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 3.0))
        runRefresh(coord(dir, db))                            // cost-only +2.0
        update(db, Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc, cost: 6.5))
        runRefresh(coord(dir, db))                            // cost-only +3.5(token 全程不變)

        let costOnly = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }
            .sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(costOnly.count, 2, "X2:兩次 cost-only 必須各自成一筆事件,不得被 keep-first 吞")
        XCTAssertEqual(Set(costOnly.map(\.id)).count, 2, "X2:兩筆必須有不同的 deterministic id")
        XCTAssertEqual(costOnly.first?.providerCostUSD ?? -1, 2.0, accuracy: 1e-6, "X2:第一筆 +2.0")
        XCTAssertEqual(costOnly.last?.providerCostUSD ?? -1, 3.5, accuracy: 1e-6, "X2:第二筆 +3.5")
        runRefresh(coord(dir, db))
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }.count,
                       2, "X2:冪等 —— replay 不得增筆")
    }

    // MARK: grok r3 X3(e2e)—— 負 boundary 不得造成全額回填
    func testX3NegativeBoundaryFailsClosedWithoutBackfill() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [Row(id: "s1", ti: 500, tu: now, tc: now - 100 * Self.msPerDay)])
        var a = CumulativeAuthority(providers: ["opencode": [:]],
                                    lastCompleteCensusMs: ["opencode": -1])
        a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
        try AtomicJSON.write(a, to: authorityURL(dir))

        let out = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 0,
                       "X3:負 boundary 必須 fail closed —— 不得把 s1 的 500 當 post-boundary 全額回填")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-baseline required") },
                      "X3:必須 loud 並指向顯式恢復")
    }

    // MARK: grok r3 X4 —— identity-invalid row:valid rows 照處理、boundary 不推、修復後 reconcile
    func testX4IdentityInvalidRowBlocksBoundaryButNotValidRows() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))
        let b1 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b1 > 0, "前置:boundary 已記錄")

        // 一列 identity-invalid(time_created = 0 —— readRows 判為無法構成 incarnation key,
        // 與 NULL 同一 code path;harness 表宣告 NOT NULL 故用 0)+ s1 正常成長。
        execRaw(db, """
        INSERT OR REPLACE INTO session VALUES ('bad','p','/Users/t/proj-a','T',
          '{"id":"m/x"}',0,50,0,0,0,0,0,\(now - Self.msPerDay));
        """)
        update(db, Row(id: "s1", ti: 130, tu: now - Self.msPerDay, tc: tc))
        let out2 = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 30, "X4:valid row 的成長必須照常入帳")
        XCTAssertEqual(authority(dir)?.lastCompleteCensusMs["opencode"], b1,
                       "X4:有無法納入 census 的列 ⇒ boundary 不得推進")
        XCTAssertTrue(out2.dashboard.dataQuality.contains { $0.contains("could not join the census") },
                      "X4:必須 loud")

        // 修復該列(tc = b1 + 1,晚於仍然有效的舊 boundary)⇒ 必須以 R1(b) 首窗 reconcile。
        execRaw(db, "UPDATE session SET time_created = \(b1 + 1) WHERE id = 'bad';")
        let out3 = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 80,
                       "X4:修復後該列必須在舊 valid boundary 下 reconcile(50 首窗計入),不得永久歧義")
        XCTAssertFalse(out3.dashboard.dataQuality.contains { $0.contains("re-baseline required") },
                       "X4:這不是歧義情境")
        XCTAssertTrue((authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0) > b1,
                      "X4:census 恢復完整後 boundary 才推進")
    }

    // MARK: grok r3 —— empty census 是合法 SUCCESS(區別於 fail-closed 的零)
    func testEmptySourceCensusSucceedsAndAdvancesBoundary() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: db, [])                                    // 有 schema、零列
        let out = runRefresh(coord(dir, db))
        XCTAssertNotNil(authority(dir), "empty census 必須留下 valid empty authority")
        let b = authority(dir)?.lastCompleteCensusMs["opencode"]
        XCTAssertNotNil(b, "empty census 是 complete census —— boundary 必須推進")
        XCTAssertTrue(anchors(dir).isEmpty, "此時尚無任何 anchor")
        XCTAssertFalse(out.dashboard.dataQuality.contains {
            $0.contains("re-baseline") || $0.contains("could not join")
        }, "empty census 不得產生 error 診斷")

        // 對照腿:boundary 之後建立的 session 首窗計入 —— 證明上面是 SUCCESS 而非 fail-closed。
        update(db, Row(id: "s2", ti: 40, tu: now, tc: (b ?? 0) + 1))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 40, "post-boundary 新 session 的首窗必須計入")
    }

    // MARK: sol r4 R4-A —— cost rollback = accounting epoch 邊界;operation id 不得回繞
    //
    // owner contract:任一 authoritative cumulative 座標倒退 ⇒ 恰一次 epoch bump、
    // 全量重錨、本輪不發事件。序列 1→3, 3→1, 1→3 的第二個 1→3 必落在新 epoch,
    // 其 canonical id 不得與第一個相同,兩個 +2 都必須入帳。
    func testR4ACostRollbackBumpsEpochSoRepeatedCostTransitionCounts() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 4 * Self.msPerDay, tc: tc, cost: 1.0)])
        runRefresh(coord(dir, db))                            // 建立(anchor cost 1,epoch 1)

        update(db, Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc, cost: 3.0))
        runRefresh(coord(dir, db))                            // cost-only +2(epoch 1)
        update(db, Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 1.0))
        runRefresh(coord(dir, db))                            // rollback ⇒ epoch 2、無事件
        XCTAssertEqual(anchors(dir)[key("s1", tc)]?.epoch, 2,
                       "R4-A:cost 倒退必須恰好推進一次 epoch")
        update(db, Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc, cost: 3.0))
        runRefresh(coord(dir, db))                            // cost-only +2(epoch 2)

        let costOnly = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }
            .sorted { $0.timestamp < $1.timestamp }
        XCTAssertEqual(costOnly.count, 2, "R4-A:兩個 +2 都必須入帳,不得被 keep-first 吞")
        XCTAssertEqual(Set(costOnly.map(\.id)).count, 2, "R4-A:重現的 cost transition 必須有不同 id(新 epoch)")
        let total = costOnly.compactMap(\.providerCostUSD).reduce(0, +)
        XCTAssertEqual(total, 4.0, accuracy: 1e-6, "R4-A:cost 貢獻合計必須是 4")
        runRefresh(coord(dir, db))
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }.count,
                       2, "R4-A:冪等")
    }

    // MARK: sol r4 R4-A(雙倒退)—— 同 snapshot token+cost 同時倒退 ⇒ epoch 恰 +1
    func testR4ASimultaneousTokenAndCostRollbackBumpsEpochExactlyOnce() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc, cost: 5.0)])
        runRefresh(coord(dir, db))
        update(db, Row(id: "s1", ti: 200, tu: now - 2 * Self.msPerDay, tc: tc, cost: 8.0))
        runRefresh(coord(dir, db))                            // +100 tokens、+3 cost(epoch 1)
        update(db, Row(id: "s1", ti: 150, tu: now - Self.msPerDay, tc: tc, cost: 2.0))
        runRefresh(coord(dir, db))                            // 兩維同倒退 ⇒ 恰一次 bump
        let a = anchors(dir)[key("s1", tc)]
        XCTAssertEqual(a?.epoch, 2, "R4-A:多維同時倒退仍必須只 bump 一次 epoch")
        XCTAssertEqual(a?.accountedThrough.input, 150, "R4-A:全量重錨到現值")
        XCTAssertEqual(a?.accountedThrough.cost ?? -1, 2.0, accuracy: 1e-9, "R4-A:cost 座標一併重錨")
        XCTAssertEqual(inputTotal(dir), 100, "R4-A:倒退輪不發事件(僅先前 +100)")
    }

    // MARK: luna r4 R4-B —— 空 sessionId:refresh 入口(排除、無 invalid anchor、boundary 不變)
    func testR4BEmptySessionIdExcludedFromCensusAndBoundaryHeld() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))
        let b1 = authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0
        XCTAssertTrue(b1 > 0, "前置:boundary 已記錄")

        execRaw(db, """
        INSERT OR REPLACE INTO session VALUES ('','p','/Users/t/proj-a','T',
          '{"id":"m/x"}',0,50,0,0,0,0,\(b1 + 1),\(now - Self.msPerDay));
        """)
        update(db, Row(id: "s1", ti: 130, tu: now - Self.msPerDay, tc: tc))
        let out = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 30, "R4-B:valid row 的成長照常入帳")
        XCTAssertFalse(anchors(dir).keys.contains { $0.hasSuffix("|") },
                       "R4-B:不得寫出空 sessionId 的 anchor key(loader 必拒的 identity)")
        XCTAssertEqual(authority(dir)?.lastCompleteCensusMs["opencode"], b1,
                       "R4-B:含 identity-invalid 列 ⇒ boundary 不得推進")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("could not join the census") },
                      "R4-B:必須 loud")
        // 下一輪 load 必須仍然成功(沒有 poison 被 durable 化)。
        let out2 = runRefresh(coord(dir, db))
        XCTAssertFalse(out2.dashboard.dataQuality.contains { $0.contains("authority rejected") },
                       "R4-B:authority 必須仍可載入 —— 不得自己寫出下一輪必 reject 的狀態")

        // recovery leg:同列取得合法 identity(tc 晚於仍有效的舊 boundary)⇒ R1(b) 首窗計入。
        execRaw(db, "DELETE FROM session WHERE id = '';")
        execRaw(db, """
        INSERT OR REPLACE INTO session VALUES ('fixed','p','/Users/t/proj-a','T',
          '{"id":"m/x"}',0,50,0,0,0,0,\(b1 + 1),\(now));
        """)
        let out3 = runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 80,
                       "R4-B recovery:修復後該列必須在最後 genuinely-complete boundary 下計首窗 50")
        XCTAssertFalse(out3.dashboard.dataQuality.contains { $0.contains("re-baseline required") },
                       "R4-B recovery:不得歧義")
        XCTAssertTrue((authority(dir)?.lastCompleteCensusMs["opencode"] ?? 0) > b1,
                      "R4-B recovery:census 恢復完整後 boundary 才推進")
    }

    // MARK: luna r4 R4-B —— re-baseline 入口:含空 sessionId 列 ⇒ .failed、authority 不變
    func testR4BRebaselineRefusesEmptySessionIdAndLeavesAuthorityUntouched() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc)])
        runRefresh(coord(dir, db))
        let before = anchors(dir)
        let bBefore = authority(dir)?.lastCompleteCensusMs["opencode"]

        execRaw(db, """
        INSERT OR REPLACE INTO session VALUES ('','p','/Users/t/proj-a','T',
          '{"id":"m/x"}',0,50,0,0,0,0,\(tc),\(now));
        """)
        let outcome = rebaseline(coord(dir, db))
        guard case .failed(let why) = outcome else {
            XCTAssertTrue(false, "R4-B:含 identity-invalid 列的 re-baseline 必須 .failed")
            return
        }
        XCTAssertTrue(why.contains("census"), "R4-B:失敗原因必須指向 census 完整性:\(why)")
        XCTAssertEqual(anchors(dir), before, "R4-B:authority anchors 必須逐欄不變")
        XCTAssertEqual(authority(dir)?.lastCompleteCensusMs["opencode"], bBefore,
                       "R4-B:boundary 必須不變")
    }

    // MARK: r5 R5-A(O2)—— sub-epsilon cost 下降也是 rollback(accounting contract 無 epsilon)
    func testR5ASubEpsilonCostDecreaseIsRollback() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 3.0)])
        runRefresh(coord(dir, db))                            // 建立(epoch 1, cost 3.0)

        // token 成長 + cost 下降 5e-7(< 1e-6)⇒ 仍必須是 rollback:epoch 恰 +1、本輪不發事件。
        update(db, Row(id: "s1", ti: 110, tu: now - Self.msPerDay, tc: tc, cost: 2.9999995))
        runRefresh(coord(dir, db))
        let a = anchors(dir)[key("s1", tc)]
        XCTAssertEqual(a?.epoch, 2, "R5-A O2:sub-epsilon cost 下降必須恰好推進一次 epoch")
        XCTAssertEqual(inputTotal(dir), 0, "R5-A O2:rollback snapshot 不得發出任何事件")
        XCTAssertEqual(a?.accountedThrough.input, 110, "R5-A O2:全量重錨到現值(token)")
        XCTAssertEqual(a?.accountedThrough.cost ?? -1, 2.9999995, accuracy: 0, "R5-A O2:cost 座標重錨(exact)")

        // 之後真實成長自新 baseline 恰好計一次。
        update(db, Row(id: "s1", ti: 150, tu: now, tc: tc, cost: 2.9999995))
        runRefresh(coord(dir, db))
        XCTAssertEqual(inputTotal(dir), 40, "R5-A O2:新 epoch 的成長恰好 +40")
    }

    // MARK: r5 R5-A(O3)—— sub-epsilon 正向 cost-only 必須恰好入帳(不得被舊 ε guard 吞)
    //
    // 本測試同時是 X5 validator 一致化的 round-trip oracle:staged pending 的
    // providerCostUSD = 5e-7 會經磁碟 round-trip 進 semantic validation —— 若 validator
    // 仍保留 1e-6 下限,這裡會以 authority-rejected 的形式紅。
    func testR5ASubEpsilonPositiveCostOnlyGrowthCounts() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 1.0)])
        runRefresh(coord(dir, db))

        update(db, Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc, cost: 1.0000005))
        let out = runRefresh(coord(dir, db))
        XCTAssertFalse(out.dashboard.dataQuality.contains { $0.contains("authority rejected") },
                       "R5-A O3:sub-eps pending 必須通過 validator(數值 contract 一致)")
        let costOnly = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }
        XCTAssertEqual(costOnly.count, 1, "R5-A O3:+0.0000005 必須自成一筆事件")
        XCTAssertEqual(costOnly.first?.providerCostUSD ?? -1, 0.0000005, accuracy: 1e-12,
                       "R5-A O3:恰好入帳 +0.0000005")
        XCTAssertEqual(anchors(dir)[key("s1", tc)]?.accountedThrough.cost ?? -1, 1.0000005,
                       accuracy: 0, "R5-A O3:baseline 同步推進(exact)")
        XCTAssertEqual(anchors(dir)[key("s1", tc)]?.epoch, 1, "R5-A O3:正向成長不 bump epoch")
        runRefresh(coord(dir, db))
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }.count,
                       1, "R5-A O3:冪等")
    }

    // MARK: r5 R5-A(O4)—— cost bit 不變:無 growth、無 rollback
    func testR5AExactlyEqualCostIsNeitherGrowthNorRollback() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 2.5)])
        runRefresh(coord(dir, db))

        update(db, Row(id: "s1", ti: 130, tu: now - Self.msPerDay, tc: tc, cost: 2.5))
        runRefresh(coord(dir, db))
        let a = anchors(dir)[key("s1", tc)]
        XCTAssertEqual(a?.epoch, 1, "R5-A O4:cost 恰等 ⇒ 不得 rollback")
        XCTAssertEqual(inputTotal(dir), 30, "R5-A O4:token 成長照常入帳")
        let tokenEv = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total > 0 }
        XCTAssertNil(tokenEv.first?.providerCostUSD, "R5-A O4:cost 恰等 ⇒ 無 provider cost(走 registry)")
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }.count,
                       0, "R5-A O4:不得產生 cost-only 事件")
        XCTAssertEqual(a?.accountedThrough.cost ?? -1, 2.5, accuracy: 0, "R5-A O4:cost 座標不動")
    }

    // MARK: sol r6 S-r6-F1(evidence-only amendment)—— persisted sub-epsilon Pending 必須真正
    // 經 fresh-process `load()` 的 semantic validation 並完成 P3 recovery
    //
    // owner normative trace:prepare 成功(pending 5e-7)→ ledger append 成功 → finalize 在
    // **pre-rename** 決定性失敗(「失敗且未變更」—— 刻意不用 post-rename outcome-unknown,
    // 隔離 X1 durability semantics)→ 銷毀 process-local state → fresh coordinator →
    // load 必須 ACCEPT(digest + semantic)→ P3:ledger 已含該 event ⇒ 不重 append、
    // finalize、清 pending → 恰一次 +0.0000005。中間前提逐一 assert,防 fixture 假綠。
    func testS6PersistedSubEpsilonPendingSurvivesFreshProcessValidationAndRecovers() throws {
        let dir = makeTempDir()
        let db = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let tc = now - 100 * Self.msPerDay
        makeDb(at: db, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay, tc: tc, cost: 1.0)])
        let rec = DurabilityOpsRecorder()
        let c1 = coord(dir, db, anchor: rec.ops)
        runRefresh(c1)                                        // process A:建立(anchor cost 1.0)

        update(db, Row(id: "s1", ti: 100, tu: now - Self.msPerDay, tc: tc, cost: 1.0000005))
        // finalize 的 file barrier(pre-rename)決定性失敗:X1 confirm(+1)、staged prepare(+2)
        // 皆過,finalize(+3)在 temp fsync 就失敗 ⇒ 磁碟 authority 仍是 staged(帶 pending)。
        let syncsBefore = rec.calls.filter { $0 == "syncFile" }.count
        rec.failSyncFileFrom = syncsBefore + 3
        runRefresh(c1)                                        // process A 的 finalize 失敗;A 結束

        // 前提 assert(缺一即 fixture 沒走到目標狀態):
        let persisted = anchors(dir)[key("s1", tc)]
        XCTAssertNotNil(persisted?.pending, "前提:pending 已 durable 留在磁碟")
        // 期望值 = 與 production 同一運算(1.0000005 - 1.0)的 exact double 差,
        // 不是字面 5e-7 —— strict contract 比的是讀入值的差,非十進位字面。
        let expectedDelta = 1.0000005 - 1.0
        XCTAssertEqual(persisted?.pending?.event.providerCostUSD ?? -1, expectedDelta, accuracy: 0,
                       "前提:pending 攜帶 exact sub-epsilon provider cost")
        XCTAssertEqual(persisted?.accountedThrough.cost ?? -1, 1.0, accuracy: 0,
                       "前提:finalize 未發生(accountedThrough 仍在 previous)")
        let costOnlyAfterCrash = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }
        XCTAssertEqual(costOnlyAfterCrash.count, 1, "前提:ledger 已含該事件(append 成功於 finalize 前)")
        let persistedId = persisted?.pending?.event.id ?? ""
        XCTAssertEqual(costOnlyAfterCrash.first?.id, persistedId, "前提:ledger 內就是 pending 的那個 event id")

        // process B:全新 coordinator(process-local state 歸零)、正常 ops。
        let c2 = coord(dir, db)
        let out = runRefresh(c2)
        XCTAssertFalse(out.dashboard.dataQuality.contains { $0.contains("authority rejected") },
                       "S6:fresh load 的 semantic validation 必須接受合法的 sub-epsilon pending")
        let after = anchors(dir)[key("s1", tc)]
        XCTAssertNil(after?.pending, "S6:P3 recovery 完成後 pending 必須清除")
        XCTAssertEqual(after?.accountedThrough.cost ?? -1, 1.0000005, accuracy: 0,
                       "S6:anchor 必須 finalize 到 intent 的 target(exact)")
        let costOnlyFinal = ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }
        XCTAssertEqual(costOnlyFinal.count, 1, "S6:ledger 已含 event ⇒ 不得重複 append")
        let total = costOnlyFinal.compactMap(\.providerCostUSD).reduce(0, +)
        XCTAssertEqual(total, expectedDelta, accuracy: 0, "S6:恰好一次 exact sub-epsilon 貢獻")
        runRefresh(coord(dir, db))
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" && $0.tokens.total == 0 }.count,
                       1, "S6:冪等")
    }
}
