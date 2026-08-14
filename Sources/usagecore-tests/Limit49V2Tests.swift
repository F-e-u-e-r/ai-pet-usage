import Foundation
@testable import UsageCore

// MARK: - #49 Plan v2 preregistered red-first(I1–I4;PLAN-v2 §cases)。
// S2 六案 characterization 與 red-first 合一:先跑現行記錄紅綠分佈(紅 = 現行與 I2 目標之差),
// audit 已排除 older-raises-newer 的既有依賴(testMonotonicGuardWithinWindow 只鎖 old-LOW 不降;
// testOldObservationsAreFullyInert 即 I2 方向)。

final class Limit49V2Tests: XCTestCase {
    private let settings = CoreSettings()

    private func isReset(_ t: LimitTransition) -> Bool { if case .reset = t { return true } else { return false } }

    private func rd(_ provider: String, _ percent: Double, at: String, resetsAt: String?) -> RateLimitReading {
        RateLimitReading(providerId: provider, observedAt: date(at),
                         primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300,
                                                         resetsAt: resetsAt.map(date)),
                         secondary: nil)
    }

    // MARK: I1 — durability provenance(cases 1/2)

    /// case 1(S1 same-process):C7c 失敗後,同 process replay 的 .unchanged 必須先 durable 再確認
    ///(重跑 barrier 成功才 .unchanged;watermark 語義由 caller 依三態行事)。
    func testV2C1SameProcessUnchangedRequiresRebarrierAfterC7c() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let batch = [rd("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let rec = DurabilityOpsRecorder(); rec.failSyncDirectory = true
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .failed = e.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "前置:C7c 注入必須 .failed"); return
        }
        rec.failSyncDirectory = false
        rec.calls.removeAll()
        // 磁碟已是 new(rename 落)但 durability 未 established;記憶體已 restore 至 old。
        // replay:fold 後與 durable(未確認)相等 —— I1:必須補一次完整 barrier 才可 .unchanged。
        // (現行:記憶體 old + 磁碟 new → fold 90? 不 —— 記憶體是 authoritative;此情境下
        //  同 engine 記憶體=old(50 未 commit... 注意 C7c 注入時 50 是首筆,restore 後記憶體=空,
        //  磁碟=new(50)。replay 50:fold 空→50 = changed → saveDurably → committed。
        //  同 process 的 .unchanged 洗白需經 reload —— 模擬 coordinator:先 reloadFromDisk。)
        e.reloadFromDisk()   // 採納 visible-but-unconfirmed new(50)
        switch e.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:02:00Z")) {
        case .unchanged:
            XCTAssertTrue(rec.calls.contains("syncFile") && rec.calls.contains("syncDirectory"),
                          "I1:unconfirmed generation 的 .unchanged 必須先補完整 barrier(得到 \(rec.calls))")
        case .committed:
            XCTAssertTrue(rec.calls.contains("syncFile"), "committed 亦可(重寫同內容),barrier 必須真跑")
        case .failed(let err):
            XCTAssertTrue(false, "replay 不應失敗(\(err))")
        }
    }

    /// case 2(S1 restart):新 process(新 engine)載入 visible-new/unconfirmed 檔 → .unchanged 前必先 durability-confirm。
    func testV2C2RestartUnchangedRequiresConfirmation() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let batch = [rd("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let rec0 = DurabilityOpsRecorder(); rec0.failSyncDirectory = true
        let e0 = LimitEngine(stateURL: url, durabilityOps: rec0.ops)
        guard case .failed = e0.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "前置"); return
        }
        // restart:fresh engine,confirmed generation 天然缺席(process 起始保守 UNCONFIRMED)。
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        switch e.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:02:00Z")) {
        case .unchanged:
            XCTAssertTrue(rec.calls.contains("syncFile") && rec.calls.contains("syncDirectory"),
                          "I1:restart 後首個 .unchanged 必須先 durable no-op 確認(得到 \(rec.calls))")
        case .committed:
            XCTAssertTrue(rec.calls.contains("syncFile"))
        case .failed(let err):
            XCTAssertTrue(false, "不應失敗(\(err))")
        }
    }

    // MARK: I2 — temporal replay authority(cases 3/4)

    /// case 3(S2 exact counterexample):[90@t1,30@t2,29@t3] commit 後 replay ⇒ 29@t3 不動、零重複 transitions。
    func testV2C3DecreaseEndingBatchReplayIdempotent() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url)
        _ = e.ingestTransitions(readings: [rd("codex", 40, at: "2026-01-15T09:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T09:01:00Z"))
        let batch = [rd("codex", 90, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z"),
                     rd("codex", 30, at: "2026-01-15T10:10:00Z", resetsAt: "2026-01-15T14:00:00Z"),
                     rd("codex", 29, at: "2026-01-15T10:20:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let t1 = e.ingestTransitions(readings: batch, settings: settings, now: date("2026-01-15T10:21:00Z"))
        XCTAssertFalse(t1.isEmpty, "首輪應有 40→90 crossings")
        let s1 = e.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                              settings: settings, now: date("2026-01-15T10:22:00Z"))
        XCTAssertEqual(s1.fiveHour.usedPercent, 29, "前置:decrease 兩筆確認 → 29")
        // replay(#49 正常 recovery 路徑)
        switch e.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:23:00Z")) {
        case .unchanged: break
        case .committed(let t):
            XCTAssertEqual(t.count, 0, "I2:replay 不得重發 transitions(得到 \(t))")
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        }
        let s2 = e.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                              settings: settings, now: date("2026-01-15T10:24:00Z"))
        XCTAssertEqual(s2.fiveHour.usedPercent, 29,
                       "I2:ts<=committed 的 90@t1 不得抬回 committed 值(replay 後仍 29)")
    }

    /// case 4(S2 六案 regression 集;owner 拍板 equal-ts 不改值)。
    func testV2C4TemporalAuthoritySixCases() {
        let e = LimitEngine(stateURL: nil)
        _ = e.ingestTransitions(readings: [rd("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:01:00Z"))
        func pct(_ at: String) -> Double? {
            e.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil), settings: settings, now: date(at))
                .fiveHour.usedPercent
        }
        // (1) older-higher → ignore(I2 核心;現行 max 會抬 = 紅)
        _ = e.ingestTransitions(readings: [rd("codex", 90, at: "2026-01-15T09:30:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:02:00Z"))
        XCTAssertEqual(pct("2026-01-15T10:02:30Z"), 50, "S2-1:older-higher 不得改 committed")
        // (2) newer-higher → raise(合法)
        _ = e.ingestTransitions(readings: [rd("codex", 60, at: "2026-01-15T10:05:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:06:00Z"))
        XCTAssertEqual(pct("2026-01-15T10:06:30Z"), 60, "S2-2:newer-higher 正常上升")
        // (3) equal-ts same value → idempotent no-op
        _ = e.ingestTransitions(readings: [rd("codex", 60, at: "2026-01-15T10:05:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:07:00Z"))
        XCTAssertEqual(pct("2026-01-15T10:07:30Z"), 60, "S2-3:equal-ts 同值冪等")
        // (4) equal-ts conflicting(較高)→ 不改 committed(owner:不用 max tie-break)
        _ = e.ingestTransitions(readings: [rd("codex", 75, at: "2026-01-15T10:05:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:08:00Z"))
        XCTAssertEqual(pct("2026-01-15T10:08:30Z"), 60, "S2-4:equal-ts 衝突值不得改 committed")
        // (5) normal two-sample decrease(既有行為不變)
        _ = e.ingestTransitions(readings: [rd("codex", 40, at: "2026-01-15T10:10:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:11:00Z"))
        _ = e.ingestTransitions(readings: [rd("codex", 41, at: "2026-01-15T10:12:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:13:00Z"))
        XCTAssertEqual(pct("2026-01-15T10:13:30Z"), 41, "S2-5:兩筆遞增確認的下修照舊")
        // (6) rollover / new window(不受 I2 影響)
        _ = e.ingestTransitions(readings: [rd("codex", 5, at: "2026-01-15T14:05:00Z", resetsAt: "2026-01-15T19:00:00Z"),
                                           rd("codex", 6, at: "2026-01-15T14:07:00Z", resetsAt: "2026-01-15T19:00:00Z")],
                                settings: settings, now: date("2026-01-15T14:08:00Z"))
        XCTAssertEqual(pct("2026-01-15T14:08:30Z"), 6, "S2-6:換窗照舊")
    }

    // MARK: I3 — reset delivery identity(cases 5/6)

    /// case 5(S3 cross-cycle):official reset durable+delivered → 之後 estimated 路徑(recency 內)零重複。
    func testV2C5OfficialThenEstimatedCrossCycleZeroDuplicate() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        // 佈置:official 窗(已知 boundary)+ estimated block 同 boundary;official 先過期並 sweep 交付。
        _ = e.ingestTransitions(readings: [rd("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:05:00Z"))
        _ = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                 now: date("2026-01-15T10:55:00Z"))
        let t1 = e.sweepExpiredWindows(now: date("2026-01-15T11:05:00Z"))
        XCTAssertEqual(t1.filter(isReset).count, 1, "前置:official reset 交付一次")
        // #83 U6/G3 rewrite(vacuity probe receipt:xcheck-49-aprime-r1/attempt-001/U6-probe-receipt.txt):
        // 舊腿宣稱測「marker save 失敗 → restore → retry」,但 official 交付已把
        // estimatedResetHandled 以同一 barrier durable 化 ⇒ 相同 blockEnd 的後續 note 是
        // **結構性 no-op**(changed=false,saveDurably 不被呼叫)——fault seam 不可達,注入
        // 從未行使(r3 G3「C5 restore 腿 vacuous」本尊)。重寫為顯式斷言該結構排除:
        // official 交付後,estimated 路徑對同 boundary 零寫入、零交付(injector 零呼叫為證);
        // seam 真行使的 failure-semantics 覆蓋 = V2C6(estimated-only fail→retry 恰一)。
        rec.calls.removeAll()
        rec.failSyncFile = true   // 若有任何寫入企圖,此注入會使其失敗——斷言證明企圖本身不存在
        let t2 = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                      blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                      now: date("2026-01-15T11:06:00Z"))
        rec.failSyncFile = false
        XCTAssertTrue(rec.calls.isEmpty,
                      "U6/G3:official 已交付 ⇒ 同 boundary 的 estimated note 必須是結構性 no-op(零 barrier 呼叫;得到 \(rec.calls))")
        XCTAssertEqual(t2.filter(isReset).count, 0,
                       "I3:同一 logical boundary,official 已交付 ⇒ estimated 任何時點不得再發(得到 \(t2))")
    }

    /// case 6(marker durable 失敗 → 零交付;retry 恰一)—— estimated 版(official 版 = AM-3 既有 lock)。
    func testV2C6EstimatedMarkerFailureZeroThenExactlyOne() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        _ = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                 now: date("2026-01-15T10:55:00Z"))
        rec.failSyncFile = true
        let t1 = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                      blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                      now: date("2026-01-15T11:05:00Z"))
        XCTAssertEqual(t1.filter(isReset).count, 0, "marker 未 durable ⇒ estimated reset 不得交付")
        rec.failSyncFile = false
        let t2 = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                      blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                      now: date("2026-01-15T11:06:00Z"))
        XCTAssertEqual(t2.filter(isReset).count, 1, "retry 成功 ⇒ 恰一次")
        let t3 = e.noteEstimatedBlock(providerId: "codex", blockEnd: date("2026-01-15T11:00:00Z"),
                                      blockTokens: 500, lastEventAt: date("2026-01-15T10:50:00Z"),
                                      now: date("2026-01-15T11:07:00Z"))
        XCTAssertEqual(t3.filter(isReset).count, 0, "已 durable handled ⇒ 不重發")
    }

    // MARK: I4 — full-reindex recovery semantics(cases 7/8;9/10 = AM-5/AM-6 既有 lock)

    private func runRefresh(_ c: UsageCoordinator, full: Bool = false) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await c.refresh(fullReindex: full); sem.signal() }
        sem.wait()
        return out!
    }

    /// case 7(S4):requested fullReindex + cumulative provider(else 路徑)⇒ full fold 語義必須生效。
    func testV2C7RequestedFullOnCumulativePathUsesFullSemantics() throws {
        let dir = makeTempDir()
        var round = 0
        let ev0 = UsageEvent(id: "v2c7", providerId: "codex", projectId: "/p", projectName: "p", modelId: "m",
                             timestamp: date("2026-01-15T09:00:00Z"), tokens: TokenBreakdown(input: 10),
                             sourceKind: "mock")
        let adapter = MockAdapter("codex", historyModel: .cumulativeSnapshotOnly) { state in
            round += 1
            let pct: Double = round == 1 ? 60 : 45
            let ob = round == 1 ? "2026-01-15T10:00:00Z" : "2026-01-15T10:30:00Z"
            return (AdapterRefreshResult(events: [ev0],
                                         rateLimits: [RateLimitReading(providerId: "codex", observedAt: date(ob),
                                                                       primary: RateLimitWindowReading(usedPercent: pct, windowMinutes: 300,
                                                                                                       resetsAt: date("2026-01-15T14:00:00Z")),
                                                                       secondary: nil)],
                                         completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c)                 // baseline 60
        _ = runRefresh(c, full: true)     // requested full + cumulative → else 路徑;45 應立即下修
        let text = String(data: (try? Data(contentsOf: dir.appendingPathComponent("limits-state.json"))) ?? Data(),
                          encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"corrected\":true") && !text.contains("pendingDecrease"),
                      "S4:requested full 必須抵達 else 路徑的 fold(corrected 直下修;state=\(text.prefix(300)))")
    }

    /// case 8(S5 process death):full 失敗 → 新 coordinator ⇒ 下輪仍 full 語義。
    /// #83 A′ 語義更新(V2C8 重寫,owner red-first 清單):full 續跑的授權來源不再是
    /// absence 推導(proto-I4,已廢——absence 單獨恆 ordinary,見 V3Row4/Row7),而是 R4
    /// pre-clear 落下的 durable intent(row 2)。斷言不變:corrected 仍出現,但機制是 intent 續跑。
    func testV2C8ProcessDeathAbsentWatermarkDerivesFullSemantics() throws {
        let dir = makeTempDir()
        var round = 0
        let ev0 = UsageEvent(id: "v2c8", providerId: "codex", projectId: "/p", projectName: "p", modelId: "m",
                             timestamp: date("2026-01-15T09:00:00Z"), tokens: TokenBreakdown(input: 10),
                             sourceKind: "mock")
        func makeAdapter() -> MockAdapter {
            MockAdapter("codex") { state in
                round += 1
                let pct: Double = round == 1 ? 60 : 45
                let ob = round == 1 ? "2026-01-15T10:00:00Z" : "2026-01-15T10:30:00Z"
                return (AdapterRefreshResult(events: [ev0],
                                             rateLimits: [RateLimitReading(providerId: "codex", observedAt: date(ob),
                                                                           primary: RateLimitWindowReading(usedPercent: pct, windowMinutes: 300,
                                                                                                           resetsAt: date("2026-01-15T14:00:00Z")),
                                                                           secondary: nil)],
                                             completeness: .complete),
                        ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
            }
        }
        let rec = DurabilityOpsRecorder()
        let c1 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeAdapter()], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c1)                 // baseline 60(watermark r1 persisted)
        rec.failSyncFile = true
        _ = runRefresh(c1, full: true)     // full 失敗:C-MF2 空 watermark 已 durable;limits commit 失敗
        // process death:全新 coordinator(pending set 消失)
        let rec2 = DurabilityOpsRecorder()
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeAdapter()], limitsDurabilityOps: rec2.ops)
        _ = runRefresh(c2)                 // ordinary 輪;row 2:durable intent(pre-clear)⇒ full 續跑
        let text = String(data: (try? Data(contentsOf: dir.appendingPathComponent("limits-state.json"))) ?? Data(),
                          encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"corrected\":true") && !text.contains("pendingDecrease"),
                      "row 2(A′):restart 後 durable intent 必須續跑 full fold 語義(state=\(text.prefix(300)))")
    }
}
