import Foundation
import SQLite3
@testable import UsageCore

// MARK: - #50 acceptance evidence(post-implementation discriminating tests)
//
// 每條測試精確描述一個 contract 與其 scenario。

final class OpenCode50AcceptanceTests: XCTestCase {

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

    private func deleteSession(_ url: URL, _ id: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK, "reopen fixture db")
        defer { sqlite3_close_v2(db) }
        exec(db, "DELETE FROM session WHERE id = '\(id)';")
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

    private func coord(_ dir: URL, _ dbURL: URL,
                       anchor: DurabilityOps? = nil,
                       ledgerOps: DurabilityOps? = nil,
                       limitsOps: DurabilityOps = .production) -> UsageCoordinator {
        var s = CoreSettings()
        s.enabledProviders = ["opencode"]
        return UsageCoordinator(dataDir: dir, settings: s, adapters: [OpenCodeAdapter(dbURL: dbURL)],
                                limitsDurabilityOps: limitsOps,
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

    private func ledger(_ dir: URL) -> UsageLedger {
        UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
    }

    private func inputTotal(_ dir: URL) -> Int {
        ledger(dir).events.filter { $0.providerId == "opencode" }.reduce(0) { $0 + $1.tokens.input }
    }

    private func authorityURL(_ dir: URL) -> URL { dir.appendingPathComponent("cumulative-anchors.json") }

    private func anchors(_ dir: URL) -> [String: CumulativeAnchor] {
        guard let a = AtomicJSON.read(CumulativeAuthority.self, from: authorityURL(dir)) else { return [:] }
        return a.providers["opencode"] ?? [:]
    }

    private func writeAnchors(_ dir: URL, _ m: [String: CumulativeAnchor]) throws {
        let store = CumulativeAnchorStore(fileURL: authorityURL(dir), durabilityOps: .production)
        try store.saveDurably(CumulativeAuthority(providers: ["opencode": m]))
    }

    private func key(_ sid: String, _ tc: Int64) -> String {
        IncarnationKey(sessionId: sid, timeCreatedMs: tc).encoded
    }

    private static let msPerDay: Int64 = 86_400_000
    private static let tc: Int64 = 1_750_000_000_000

    /// 建立 authority(zero-delta,不發事件)。
    private func establish(_ dir: URL, _ dbURL: URL) {
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 0, "establishment 不得產生事件")
    }

    // MARK: - first-contact 產品 contract regression
    //
    // OpenCode 的記帳自**第一次可信觀測**起算;觀測之前既有的 cumulative 總量只用來建立
    // zero-delta baseline,不得回填成歷史用量。
    func testFirstContactEstablishesZeroDeltaAndDoesNotBackfill() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 1_000_000, tu: now - Self.msPerDay)])

        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 0, "既有 1,000,000 不得被回填成一筆歷史用量")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 1_000_000,
                       "但必須成為 baseline")

        update(dbURL, Row(id: "s1", ti: 1_020_000, tu: now))
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 20_000, "只有觀測之後真正發生的 20,000 才計入")
    }

    // MARK: - A1 / A3:來源列永久消失後,recovery 仍能自 Pending 完成
    //
    // 並驗 canonical equality:重播的 event 必須與當初準備的 event **完全相同**,
    // 而不只是 token 總量相同。
    func testA1A3SourceRowGoneRecoveryReplaysExactPreparedEvent() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay)])
        establish(dir, dbURL)

        // 成長後令 ledger 寫入失敗 ⇒ pending durable、帳本無該事件。
        update(dbURL, Row(id: "s1", ti: 160, tu: now - Self.msPerDay))
        let rec = DurabilityOpsRecorder()
        rec.failSyncFile = true
        runRefresh(coord(dir, dbURL, ledgerOps: rec.ops))
        XCTAssertEqual(inputTotal(dir), 0, "A3 前置:帳本未寫入")
        guard let pend = anchors(dir)[key("s1", Self.tc)]?.pending else {
            XCTAssertTrue(false, "A3 前置:pending 必須 durable 留存")
            return
        }
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 100,
                       "A3 前置:accountedThrough 不得在 prepare 階段推進")

        // 來源列永久消失。
        deleteSession(dbURL, "s1")
        runRefresh(coord(dir, dbURL))

        let appended = ledger(dir).events.filter { $0.providerId == "opencode" }
        XCTAssertEqual(appended.count, 1, "A1:來源消失後仍必須完成該筆記帳")
        XCTAssertTrue(appended.first == pend.event,
                      "A1:重播的 event 必須與當初準備的 event canonical 相等(非僅 token 總量)")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 160,
                       "A3:重播成功後 finalize")
        XCTAssertNil(anchors(dir)[key("s1", Self.tc)]?.pending, "A3:pending 已清除")
    }

    // MARK: - A2:帳本已有該事件 ⇒ 不得重複 append,直接 finalize
    func testA2LedgerAlreadyHasEventFinalizesWithoutDuplicate() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay)])
        establish(dir, dbURL)

        // ledger 寫入成功、finalize 失敗 ⇒ pending 留存且帳本已有該事件。
        update(dbURL, Row(id: "s1", ti: 160, tu: now - Self.msPerDay))
        let rec = DurabilityOpsRecorder()
        rec.failSyncFileFrom = 3          // #1 = X1 confirm、#2 = staged、#3 = finalize 起失敗
        runRefresh(coord(dir, dbURL, anchor: rec.ops))
        XCTAssertEqual(inputTotal(dir), 60, "A2 前置:帳本已 durable")
        XCTAssertNotNil(anchors(dir)[key("s1", Self.tc)]?.pending, "A2 前置:pending 留存")

        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(ledger(dir).events.filter { $0.providerId == "opencode" }.count, 1,
                       "A2:不得重複 append")
        XCTAssertEqual(inputTotal(dir), 60, "A2:總量不變")
        XCTAssertNil(anchors(dir)[key("s1", Self.tc)]?.pending, "A2:pending 已清除")
    }

    // MARK: - A4:過期 pending 不得 resurrection,但必須 finalize
    func testA4ExpiredPendingFinalizesWithoutResurrection() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Date()
        let oldMs = Int64((now.timeIntervalSince1970 - 200 * 86400) * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 160, tu: oldMs)])

        // 人為構造:accountedThrough=100、pending 目標 160,事件時間戳遠早於保留窗。
        let prev = AnchorCounters(input: 100)
        let target = AnchorCounters(input: 160)
        let ev = UsageEvent(id: IncarnationKey(sessionId: "s1", timeCreatedMs: Self.tc)
                                .eventId(epoch: 1, previous: prev, target: target),
                            providerId: "opencode", projectId: "/Users/t/proj-a",
                            projectName: "proj-a", modelId: "m/x",
                            timestamp: Date(timeIntervalSince1970: TimeInterval(oldMs) / 1000),
                            tokens: TokenBreakdown(input: 60), sourceKind: "opencode-session",
                            sourcePath: dbURL.path, providerCostUSD: nil)
        try writeAnchors(dir, [key("s1", Self.tc): CumulativeAnchor(
            epoch: 1, accountedThrough: prev,
            pending: PendingReconciliation(event: ev, previous: prev, target: target, epoch: 1))])

        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 0, "A4:過期 intent 不得被 resurrection")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 160,
                       "A4:仍必須 finalize 到 intent 的 target")
        XCTAssertNil(anchors(dir)[key("s1", Self.tc)]?.pending, "A4:pending 已清除")
    }

    // MARK: - R-retention:cutoff 三個邊界必須與 compaction 完全一致
    //
    // 不在測試內複製 `<` / `<=`;直接以共用 helper 的語義為準,兩邊只有一份實作。
    func testRetentionCutoffBoundariesMatchCompaction() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = UsageLedger.retentionCutoff(retentionDays: 92, now: now)

        XCTAssertTrue(UsageLedger.isExpired(cutoff.addingTimeInterval(-1), retentionDays: 92, now: now),
                      "cutoff - 1s 必須算過期")
        XCTAssertFalse(UsageLedger.isExpired(cutoff, retentionDays: 92, now: now),
                       "恰好等於 cutoff 不算過期")
        XCTAssertFalse(UsageLedger.isExpired(cutoff.addingTimeInterval(1), retentionDays: 92, now: now),
                       "cutoff + 1s 不算過期")

        // 與 compaction 的實際行為對照:恰在 cutoff 的事件必須被保留。
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        let l = UsageLedger(fileURL: file)
        _ = l.append([
            UsageEvent(id: "at-cutoff", providerId: "opencode", timestamp: cutoff,
                       tokens: TokenBreakdown(input: 1), sourceKind: "t"),
            UsageEvent(id: "before-cutoff", providerId: "opencode",
                       timestamp: cutoff.addingTimeInterval(-1),
                       tokens: TokenBreakdown(input: 1), sourceKind: "t"),
        ])
        _ = l.compact(retentionDays: 92, now: now)
        XCTAssertEqual(l.events.map(\.id), ["at-cutoff"],
                       "compaction 必須丟棄 cutoff 之前、保留恰在 cutoff 者 —— 與 isExpired 同義")
    }

    // 註:原 `testB2aGenuinelyNewIncarnationEstablishesAutomatically` 已移除 —— 其斷言
    // 建立在「新 incarnation 全額計入」的錯誤契約上,由 contract matrix C2/C3 取代。

    // MARK: - B2b:曾知悉的 incarnation 其 anchor 消失 ⇒ 必須 fail closed
    //
    // 這條防止今日追認的 zero-delta 語義被誤用成「找不到 anchor 就重設」。
    func testB2bMissingKnownAuthorityFailsClosed() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay)])
        establish(dir, dbURL)
        update(dbURL, Row(id: "s1", ti: 150, tu: now - 2 * Self.msPerDay))
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 50, "前置:已入帳 50")

        // 自 authority 檔中移除該筆 record(digest 未重算)。
        var a = try AtomicJSON.decoder().decode(CumulativeAuthority.self,
                                                from: try Data(contentsOf: authorityURL(dir)))
        a.providers["opencode"]?.removeValue(forKey: key("s1", Self.tc))
        try AtomicJSON.write(a, to: authorityURL(dir))

        update(dbURL, Row(id: "s1", ti: 400, tu: now))
        let out = runRefresh(coord(dir, dbURL))

        XCTAssertEqual(inputTotal(dir), 50,
                       "B2b:authority 不完整時不得產生任何記帳異動")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-baseline") },
                      "B2b:必須 loud 並要求顯式 re-baseline")
    }

    // MARK: - B2c:authority 檔整份消失但已有記帳證據 ⇒ fail closed(不得自動重設)
    func testB2cAbsentAuthorityWithPriorEvidenceFailsClosed() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 3 * Self.msPerDay)])
        establish(dir, dbURL)
        update(dbURL, Row(id: "s1", ti: 150, tu: now - 2 * Self.msPerDay))
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 50, "前置:已入帳 50")

        try FileManager.default.removeItem(at: authorityURL(dir))
        update(dbURL, Row(id: "s1", ti: 400, tu: now))
        let out = runRefresh(coord(dir, dbURL))

        XCTAssertEqual(inputTotal(dir), 50, "B2c:不得自動 zero-baseline 或重算")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-baseline") },
                      "B2c:必須 loud 並要求顯式 re-baseline")
    }

    // MARK: - E1:limits 連續失敗不得回撤已提交的帳,亦不得重複計入
    func testE1LimitsRepeatedFailureKeepsAccountingExactlyOnce() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 5 * Self.msPerDay)])
        establish(dir, dbURL)

        let rec = DurabilityOpsRecorder()
        rec.failSyncFile = true          // limits barrier 一律失敗
        update(dbURL, Row(id: "s1", ti: 160, tu: now - 4 * Self.msPerDay))
        runRefresh(coord(dir, dbURL, anchor: .production, limitsOps: rec.ops))
        XCTAssertEqual(inputTotal(dir), 60, "E1:ledger durable 成功 ⇒ 帳已提交")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 160,
                       "E1:limits 失敗不得阻止 anchor finalize(P1)")

        // limits 再失敗兩輪,期間來源不變 ⇒ 不得重複計入、不得回撤。
        for _ in 0..<2 {
            runRefresh(coord(dir, dbURL, anchor: .production, limitsOps: rec.ops))
        }
        XCTAssertEqual(inputTotal(dir), 60, "E1:連續失敗不得重複計入或回撤")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 160,
                       "E1:anchor 不得 rollback")
    }

    // MARK: - E2:limits 恢復後必須自 durable ledger 補齊 projection
    func testE2LimitsRecoversProjectionFromDurableLedger() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 5 * Self.msPerDay)])
        establish(dir, dbURL)

        let rec = DurabilityOpsRecorder()
        rec.failSyncFile = true
        update(dbURL, Row(id: "s1", ti: 160, tu: now - 4 * Self.msPerDay))
        runRefresh(coord(dir, dbURL, anchor: .production, limitsOps: rec.ops))
        XCTAssertEqual(inputTotal(dir), 60, "E2 前置:帳已提交而 limits 失敗")

        // limits 恢復:同一 provider 的 reconciliation identity 必須被補建,且不得重複計帳。
        let out = runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 60, "E2:補投不得重複計入")
        XCTAssertNil(out.dashboard.dataQuality.first { $0.contains("limits projection failed") },
                     "E2:恢復後不應再報 limits 失敗")

        let limitsState = AtomicJSON.read([String: [String: AnyCodableProbe]].self,
                                          from: dir.appendingPathComponent("limits-state.json"))
        XCTAssertNotNil(limitsState, "E2:limits state 必須已 durable 落盤(自 ledger 補投)")
    }
    // MARK: - legacy `refreshUsage` 必須是 production-unreachable
    //
    // coordinator 的兩個 legacy 呼叫點各自被靜態守住:一個要求 `.rebuildableHistory`,
    // 另一個的 else 只在 `adapter as? CumulativeAnchorAdapter` 失敗時進入。兩者都建立在
    // 下面兩個前提上;若未來有人拿掉 conformance 或改 historyModel,legacy(pre-#50 語義)
    // 路徑會被默默打開而不會有其他測試變紅。
    func testLegacyRefreshUsageRemainsProductionUnreachable() {
        let a = OpenCodeAdapter()
        XCTAssertEqual(a.historyModel, .cumulativeSnapshotOnly,
                       "前提 1:非 rebuildable ⇒ 不進入呼叫 legacy refreshUsage 的 full-rescan 分支")
        XCTAssertTrue(a is CumulativeAnchorAdapter,
                      "前提 2:conform CumulativeAnchorAdapter ⇒ 恆走 anchored 分支")
    }
    // MARK: - #50 explicit re-baseline recovery

    private func rebaseline(_ c: UsageCoordinator) -> UsageCoordinator.RebaselineOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: UsageCoordinator.RebaselineOutcome?
        Task { out = await c.rebaselineCumulative(providerId: "opencode"); sem.signal() }
        sem.wait()
        return out!
    }

    /// 建立「legacy 證據存在但無 authority」的升級態:帳本已有歷史、scan-state 帶 legacy context。
    private func seedLegacyUpgradeState(_ dir: URL, _ dbURL: URL, sourceTotal: Int, legacyBaseline: Int) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: sourceTotal, tu: now - Self.msPerDay)])
        let ev = UsageEvent(id: "oc:s1:1:0", providerId: "opencode", projectId: "/p", projectName: "p",
                            modelId: "m/x",
                            timestamp: Date(timeIntervalSince1970: Double(now) / 1000 - 86400),
                            tokens: TokenBreakdown(input: legacyBaseline),
                            sourceKind: "opencode-session", sourcePath: dbURL.path, providerCostUSD: nil)
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).append([ev])
        var ss = ScanState()
        ss.files[dbURL.path] = FileScanMark(offset: now, size: 0,
            context: ["schema": "1", "s:s1": "1,\(legacyBaseline),0,0,0,0.000000"])
        try AtomicJSON.write(["opencode": ss], to: dir.appendingPathComponent("scan-state.json"))
    }

    // 1) legacy 證據 + 無 authority ⇒ 正常 refresh fail closed,且診斷指向 re-baseline recovery
    func testR1LegacyEvidenceWithoutAuthorityFailsClosedAndNamesRecovery() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        try seedLegacyUpgradeState(dir, dbURL, sourceTotal: 500, legacyBaseline: 100)

        let out = runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 100, "R1:不得產生任何新記帳")
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-baseline") },
                      "R1:診斷必須指向 explicit re-baseline recovery")
        XCTAssertTrue(anchors(dir).isEmpty, "R1:不得建立任何 authority")
    }

    // 2/3/4/7/8) 顯式 re-baseline:現值成為 authority、零用量;legacy 值永不被複製;既有帳本不動
    func testR2ExplicitRebaselineEstablishesCurrentCountersAndCountsOnlyLaterGrowth() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try seedLegacyUpgradeState(dir, dbURL, sourceTotal: 500, legacyBaseline: 100)
        let ledgerBefore = try Data(contentsOf: dir.appendingPathComponent("ledger.jsonl"))

        XCTAssertEqual(rebaseline(coord(dir, dbURL)), .ok(sessions: 1), "R2:re-baseline 應成功")

        // 2) 現值成為 authority;7) legacy 的 100 絕不得被複製進來
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 500,
                       "R2/R7:baseline 必須是**來源現值** 500,而非 legacy 的 100")
        XCTAssertEqual(inputTotal(dir), 100, "R2:re-baseline 本身不得產生用量")
        // 8) 既有已保留的歷史帳本逐位元組不動
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("ledger.jsonl")), ledgerBefore,
                       "R8:re-baseline 不得改寫/回填/刪除既有帳本")

        // 3) re-baseline 後首輪且無成長 ⇒ 零用量
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 100, "R3:無成長 ⇒ 零新用量")

        // 4) 之後真實成長 ⇒ 恰好計一次
        update(dbURL, Row(id: "s1", ti: 530, tu: now))
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 130, "R4:只計 re-baseline 之後的 30")
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 130, "R4:重跑不得重複計入")
    }

    // 5) 來源不可用 ⇒ 失敗且不得變更 authority
    func testR5RebaselineWithUnavailableSourceFailsWithoutMutation() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay)])
        establish(dir, dbURL)
        let before = anchors(dir)

        try FileManager.default.removeItem(at: dbURL)
        let outcome = rebaseline(coord(dir, dbURL))
        // 不只驗「失敗」—— 還要驗它是被**來源可用性前置檢查**擋下的。
        // 否則 census 自己的開檔失敗也會讓本測試通過,守門是否存在就無法被鑑別。
        guard case .failed(let why) = outcome else {
            XCTAssertTrue(false, "R5:來源不可用時必須失敗")
            return
        }
        XCTAssertTrue(why.contains("source is unavailable"),
                      "R5:必須由來源可用性前置檢查擋下(在取鎖之前),而非落到 census 的開檔失敗")
        XCTAssertEqual(anchors(dir), before, "R5:authority 必須逐欄不變")
    }

    // 6) durable 寫入失敗 ⇒ 失敗且舊 authority 仍為權威(無 partial success)
    func testR6RebaselineDurableWriteFailureLeavesPreviousAuthority() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - Self.msPerDay)])
        establish(dir, dbURL)
        let before = anchors(dir)

        update(dbURL, Row(id: "s1", ti: 900, tu: now))
        let rec = DurabilityOpsRecorder()
        rec.failSyncFile = true
        let outcome = rebaseline(coord(dir, dbURL, anchor: rec.ops))
        if case .failed = outcome {} else { XCTAssertTrue(false, "R6:durable 寫入失敗時必須失敗") }
        XCTAssertEqual(anchors(dir), before, "R6:舊 authority 仍為權威,不得留下 partial state")
    }

    // 9) 對健康 authority 亦可顯式 re-baseline(recovery 與 migration 共用同一語義)
    func testR9RebaselineOnHealthyAuthorityIsAllowed() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay)])
        establish(dir, dbURL)
        update(dbURL, Row(id: "s1", ti: 160, tu: now - Self.msPerDay))
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 60, "前置:已入帳 60")

        update(dbURL, Row(id: "s1", ti: 900, tu: now))
        XCTAssertEqual(rebaseline(coord(dir, dbURL)), .ok(sessions: 1), "R9:健康 authority 亦可顯式重設")
        XCTAssertEqual(anchors(dir)[key("s1", Self.tc)]?.accountedThrough.input, 900,
                       "R9:baseline 重錨到現值")
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 60, "R9:重設不得回填 60→900 之間的差額")
    }
    // MARK: - xcheck r1 findings 的第一手重現(不修復,只證明)

    /// grok F1:對「無任何 session 的來源」成功刷新會 materialize 一份 durable 空 authority,
    /// 之後第一次真實觀測便走「authority 已建立 ⇒ 新 key」路徑,而非 zero-delta establishment。
    func testReproGrokF1EmptySourceMaterializesAuthorityDefeatingZeroDeltaFirstContact() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [])                       // 來源存在但沒有任何 session
        runRefresh(coord(dir, dbURL))               // 成功刷新 ⇒ 是否寫出空 authority?

        // 之後才第一次看到一個已有大量歷史的 session。
        update(dbURL, Row(id: "s1", ti: 1_000_000, tu: now - Self.msPerDay))
        runRefresh(coord(dir, dbURL))

        XCTAssertEqual(inputTotal(dir), 0,
                       "F1:第一次真實觀測仍必須是 zero-delta establishment,不得回填既有 1,000,000")
    }

    // 註:原 `testReproGrokF2RebaselineDropsAbsentIncarnationAuthority` 已退役 —— R2 落地後
    // re-baseline 保留未觀測到的既有 anchor,該缺陷不再存在;契約由 C6 持續守護。

    /// luna F1:explicit re-baseline 會抹掉尚未落盤的 durable pending,並把 anchor 推到
    /// 該 span 之上 —— 該筆用量永遠不會進帳,且 anchor 超前 ledger(靜默漏計)。
    func testReproLunaF1RebaselineErasesPendingAndLeadsLedger() throws {
        let dir = makeTempDir()
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        makeDb(at: dbURL, [Row(id: "s1", ti: 100, tu: now - 2 * Self.msPerDay)])
        establish(dir, dbURL)

        // 造出 durable pending:ledger 寫入失敗。
        update(dbURL, Row(id: "s1", ti: 160, tu: now - Self.msPerDay))
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        runRefresh(coord(dir, dbURL, ledgerOps: rec.ops))
        XCTAssertNotNil(anchors(dir)[key("s1", Self.tc)]?.pending, "前置:pending durable")
        XCTAssertEqual(inputTotal(dir), 0, "前置:帳本尚無該事件")

        // 使用者此時執行 re-baseline。
        XCTAssertEqual(rebaseline(coord(dir, dbURL)), .ok(sessions: 1))

        // 該 pending 的 60 從未進帳,而 anchor 卻已涵蓋它。
        runRefresh(coord(dir, dbURL))
        XCTAssertEqual(inputTotal(dir), 60,
                       "luna F1:未落盤的 pending 用量不得因 re-baseline 而永久消失")
    }

    // 註:原 `testReproLunaF2EventIdCollidesAcrossIncarnations` 已退役 —— R3 落地後事件 id
    // 綁定 incarnation,該碰撞不再可能;契約由 C4 持續守護。

}





/// 只為在測試中確認 limits-state.json 可解碼的極小 probe。
struct AnyCodableProbe: Codable {}