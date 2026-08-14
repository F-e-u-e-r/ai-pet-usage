import Foundation
@testable import UsageCore

// MARK: - #49 R4 replay/idempotence CHARACTERIZATION(PLAN-v1 phase 2;對「現行」engine,
// 零產品碼改動)。Pre-registered PASS bar:三案全綠 ⇒ 進 red-first;任一紅 ⇒ 停回 owner gate
//(replay/transition identity 需重設計,不得 inline 發明 notification dedupe)。
// 機制假說(待執行證明):同窗單調 max()、crossings 只在 percent>previous 發、
// observedAt 嚴格遞增防護(pending 不可自我確認)、reset recency gate。

final class Limit49CharacterizationTests: XCTestCase {
    private let settings = CoreSettings()

    private func providerOf(_ t: LimitTransition) -> String {
        switch t {
        case .reset(let p, _, _): return p
        case .crossedThreshold(let p, _, _, _): return p
        case .exhausted(let p, _): return p
        }
    }
    private func isReset(_ t: LimitTransition) -> Bool { if case .reset = t { return true } else { return false } }

    private func reading(_ provider: String, _ percent: Double, at: String, resetsAt: String,
                         weekly: Double = 50) -> RateLimitReading {
        RateLimitReading(
            providerId: provider,
            observedAt: date(at),
            primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300, resetsAt: date(resetsAt)),
            secondary: RateLimitWindowReading(usedPercent: weekly, windowMinutes: 10080,
                                              resetsAt: date("2026-01-20T00:00:00Z"))
        )
    }

    /// C-A:整批 replay(同 observedAt)⇒ 零 transitions、logical store 不變。
    /// 批內含 threshold crossing(30→85 跨多閾)確保首輪確實發過 transitions。
    func testReplayFullBatchEmitsNoTransitionsAndPreservesStore() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url)
        let batch = [reading("codex", 30, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z"),
                     reading("codex", 85, at: "2026-01-15T11:00:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let now = date("2026-01-15T11:05:00Z")
        let t1 = e.ingestTransitions(readings: batch, settings: settings, now: now)
        XCTAssertFalse(t1.isEmpty, "首輪必須真的發過 transitions(crossing 30→85),否則本案無鑑別力")
        let stateAfterFirst = try? Data(contentsOf: url)
        XCTAssertNotNil(stateAfterFirst)
        // replay:crash-before-scan-state 後的正常 recovery path(同批、同 observedAt)。
        // #49 三態(matrix row 6/10):replay 必須回 .unchanged(watermark 可追上、不強迫重寫)。
        guard case .unchanged = e.ingest(readings: batch, settings: settings, now: now) else {
            XCTAssertTrue(false, "replay 必須回 .unchanged(row 6/10)"); return
        }
        let stateAfterReplay = try? Data(contentsOf: url)
        XCTAssertEqual(stateAfterReplay, stateAfterFirst, "replay 後 durable store 不得被重寫(bytes 相等)")
    }

    /// C-B(owner 新增 case):shared whole-file store —— A ingest(發 transitions)後假設 A 的
    /// save 失敗(watermark 停舊);B 之後成功 save 順帶把 A 的記憶體態持久化;A replay ⇒
    /// A 收斂且零重複 A-transitions。
    func testCrossProviderSharedStoreReplayConverges() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url)
        let batchA = [reading("codex", 20, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z"),
                      reading("codex", 90, at: "2026-01-15T11:00:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let now = date("2026-01-15T11:05:00Z")
        let tA1 = e.ingestTransitions(readings: batchA, settings: settings, now: now)
        XCTAssertFalse(tA1.isEmpty)
        // B 的 ingest 走同一 engine(whole-file save 順帶持久化 A 的記憶體態 —— 現行 save() 即如此)。
        let batchB = [reading("claude-code", 40, at: "2026-01-15T11:02:00Z", resetsAt: "2026-01-15T15:00:00Z")]
        _ = e.ingestTransitions(readings: batchB, settings: settings, now: now)
        // A 的 watermark 停舊 → 下輪重掃 replay A 的整批(B 已把 A 態帶上磁碟;重開 engine 模擬新一輪)。
        let e2 = LimitEngine(stateURL: url)
        let tA2 = e2.ingestTransitions(readings: batchA, settings: settings, now: now)
        let dupA = tA2.filter { self.providerOf($0) == "codex" }
        XCTAssertEqual(dupA.count, 0, "A replay 不得重發 A-transitions(得到 \(dupA))")
    }

    // MARK: - #49 red-first matrix(rows 1/2/3+8/7/9;PLAN-v1 §matrix)。
    // 紀律註記:實作與測試同批落地(順序偏差)——failure 綁定改以 falsification 證明
    //(拔接線 → 紅 → 恢復 → 綠;#64 同法,證明力等價),結果記於 plan/報告。

    /// row 1:syncFile(F_FULLFSYNC)失敗 ⇒ .failed、durable store 舊 bytes 原封、watermark 語義由 caller 擋。
    func testRow1SyncFileFailureFailsClosedOldDurable() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let seed = LimitEngine(stateURL: url)
        _ = seed.ingestTransitions(readings: [reading("codex", 10, at: "2026-01-15T09:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                   settings: settings, now: date("2026-01-15T09:01:00Z"))
        let before = try Data(contentsOf: url)
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .failed = e.ingest(readings: [reading("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                      settings: settings, now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "row1:barrier 失敗必須 .failed"); return
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "row1:old limits durable 原封")
        XCTAssertTrue(rec.calls.contains("syncFile"), "barrier 必須真的被呼叫")
        XCTAssertFalse(rec.calls.contains("rename"), "syncFile 敗後不得 rename")
    }

    /// row 2:rename 失敗 ⇒ .failed、old durable 原封。
    func testRow2RenameFailureFailsClosedOldDurable() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let seed = LimitEngine(stateURL: url)
        _ = seed.ingestTransitions(readings: [reading("codex", 10, at: "2026-01-15T09:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                   settings: settings, now: date("2026-01-15T09:01:00Z"))
        let before = try Data(contentsOf: url)
        let rec = DurabilityOpsRecorder(); rec.failRename = true
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .failed = e.ingest(readings: [reading("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                      settings: settings, now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "row2:rename 失敗必須 .failed"); return
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "row2:old durable 原封")
    }

    /// row 3+8:post-rename dir-fsync 失敗 ⇒ .failed(watermark 由 caller 擋)、durability {old|new};
    /// 重開 engine 後 replay ⇒ .unchanged 收斂(reloadFromDisk-after-unknown 的收斂即 row 8)。
    func testRow3DirSyncFailureOutcomeUnknownReplayConverges() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let batch = [reading("codex", 50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")]
        let rec = DurabilityOpsRecorder(); rec.failSyncDirectory = true
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .failed = e.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "row3:dir-fsync 失敗必須 .failed(即使 rename 已可見)"); return
        }
        // {old|new} 皆 valid;此注入下真 rename 已跑(實際=new)。重開(reload)+ replay ⇒ 收斂不重發。
        let e2 = LimitEngine(stateURL: url)
        switch e2.ingest(readings: batch, settings: settings, now: date("2026-01-15T10:02:00Z")) {
        case .unchanged: break   // new 已 durable → replay no-op ✓
        case .committed(let t):
            XCTAssertEqual(t.filter(isReset).count, 0, "row8:replay 收斂不得重發 reset")
        case .failed(let err):
            XCTAssertTrue(false, "row8:replay 不得失敗(\(err))")
        }
    }

    /// row 7(coordinator 級):limits durable commit 不成立(poison 路徑)⇒ provider watermark 不推進
    ///(以 MockAdapter.lastSeenState 驗)、refreshErrors 可觀測;ledger append 照常。
    private func runRefresh49(_ coord: UsageCoordinator) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await coord.refresh(); sem.signal() }
        sem.wait()
        return out!
    }

    func testRow7CoordinatorHoldsWatermarkWhenLimitsCommitFails() throws {
        let dir = makeTempDir()
        let ev = UsageEvent(id: "e49", providerId: "codex", projectId: "/p", projectName: "p", modelId: "m",
                            timestamp: date("2026-01-15T10:00:00Z"), tokens: TokenBreakdown(input: 10),
                            sourceKind: "mock")
        let adapter = MockAdapter("codex") { state in
            (AdapterRefreshResult(events: [ev],
                                  rateLimits: [RateLimitReading(providerId: "codex", observedAt: date("2026-01-15T10:00:00Z"),
                                                                primary: RateLimitWindowReading(usedPercent: 50, windowMinutes: 300,
                                                                                                resetsAt: date("2026-01-15T14:00:00Z")),
                                                                secondary: nil)],
                                  completeness: .complete),
             ScanState(files: ["m\(state.files.count)": FileScanMark(offset: 1, size: 1)]))
        }
        // 注入 syncFile 失敗(coordinator internal init,mirror #64 DP-3)⇒ ingest .failed。
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh49(c)
        XCTAssertEqual(adapter.lastSeenState?.files.count ?? -1, 0, "第一輪 adapter 應收到空 state")
        _ = runRefresh49(c)
        XCTAssertEqual(adapter.lastSeenState?.files.count ?? -1, 0,
                       "row7:limits durable 失敗 ⇒ watermark 不得推進(第二輪仍收到空 state)")
    }

    /// row 9(engine 級):derived(estimatedBlock)持久化失敗 ⇒ derivedSaveError 可觀測(loud)、
    /// 不 throw、不擋任何 watermark 語義(coordinator 只轉 note)。
    func testRow9DerivedSaveFailureIsLoudButNonblocking() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T12:00:00Z"),
                                 blockTokens: 100, lastEventAt: date("2026-01-15T10:00:00Z"),
                                 now: date("2026-01-15T10:05:00Z"))
        XCTAssertNotNil(e.derivedSaveError, "row9:derived save 失敗必須 loud(derivedSaveError)")
    }

    // MARK: - #49 amendment red-first(owner 7 格;寫於 production 改動前——真紅)

    /// AM-1 dirty-laundering:ingest durable-save 注入失敗 → 續跑 sweep(derived 路徑)⇒
    /// failed-ingest 態**永不落盤**(FAILED 純度 + 唯一 durable primitive 的合璧斷言)。
    func testAM1FailedIngestStateNeverLaunderedByDerivedSave() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        // durable baseline:60%、resetsAt 已過(給 sweep 一個可動的 expiry)
        let seed = LimitEngine(stateURL: url)
        _ = seed.ingestTransitions(readings: [reading("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                   settings: settings, now: date("2026-01-15T10:05:00Z"))
        let durableBefore = try Data(contentsOf: url)
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .failed = e.ingest(readings: [reading("codex", 90, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                      settings: settings, now: date("2026-01-15T10:31:00Z")) else {
            XCTAssertTrue(false, "前置:注入下 ingest 必須 .failed"); return
        }
        rec.failSyncFile = false   // derived 路徑的寫入本身讓它成功——考驗的是「寫的內容」
        _ = e.sweepExpiredWindows(now: date("2026-01-15T11:20:00Z"))
        let after = (try? Data(contentsOf: url)) ?? durableBefore
        let text = String(data: after, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"percent\":90") || text.contains("\"percent\": 90"),
                       "AM-1:failed ingest 的 90% 絕不得經 derived save 落盤")
    }

    /// AM-2 成功 ingest 後的 derived rewrite 也必須走完整 barrier(唯一 durable primitive)。
    func testAM2DerivedRewriteGoesThroughFullBarrier() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        _ = e.ingestTransitions(readings: [reading("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:05:00Z"))
        rec.calls.removeAll()
        _ = e.sweepExpiredWindows(now: date("2026-01-15T11:05:00Z"))   // expiry 已過 → marker 變 → 寫
        XCTAssertEqual(rec.calls, ["syncFile", "rename", "syncDirectory"],
                       "AM-2:derived 寫入必須走同一 durable barrier(得到 \(rec.calls))")
    }

    /// AM-3 sweep = durable-marker-before-delivery:save 失敗 ⇒ 0 transitions;retry 成功 ⇒ 恰一次。
    func testAM3SweepMarkerDurableBeforeResetDelivery() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        _ = e.ingestTransitions(readings: [reading("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:05:00Z"))
        rec.failSyncFile = true
        let t1 = e.sweepExpiredWindows(now: date("2026-01-15T11:05:00Z"))
        XCTAssertEqual(t1.filter(isReset).count, 0, "AM-3:marker 未 durable ⇒ reset 不得交付(得到 \(t1))")
        rec.failSyncFile = false
        let t2 = e.sweepExpiredWindows(now: date("2026-01-15T11:06:00Z"))
        XCTAssertEqual(t2.filter(isReset).count, 1, "AM-3:retry 成功 ⇒ 恰一次 reset(得到 \(t2))")
        let t3 = e.sweepExpiredWindows(now: date("2026-01-15T11:07:00Z"))
        XCTAssertEqual(t3.filter(isReset).count, 0, "AM-3:marker 已 durable ⇒ 不重發")
    }

    /// AM-4/5 fullReindex retry(coordinator 級):full ingest 失敗 → 下輪仍以 full 語義 fold
    ///(lower 讀數立即生效,非 pending);retry 完成後 intent 清除、watermark 追上。
    /// #83 A′ 語義更新:retry 載體從 process-local pending set 改為 row 2 續跑(R4 pre-clear 的
    /// durable intent:pendingFullReconcile ∧ ack==gen)——same-process 與 restart 走同一判定,
    /// 斷言不變,機制由 classifyProviderStart 承擔。
    func testAM45FullReindexRetrySemanticsAndUnchangedClears() throws {
        let dir = makeTempDir()
        var round = 0
        let ev0 = UsageEvent(id: "e49b", providerId: "codex", projectId: "/p", projectName: "p", modelId: "m",
                             timestamp: date("2026-01-15T09:00:00Z"), tokens: TokenBreakdown(input: 10),
                             sourceKind: "mock")
        let adapter = MockAdapter("codex") { _ in
            round += 1
            let readings: [RateLimitReading]
            if round == 1 {
                readings = [RateLimitReading(providerId: "codex", observedAt: date("2026-01-15T10:00:00Z"),
                                             primary: RateLimitWindowReading(usedPercent: 60, windowMinutes: 300,
                                                                             resetsAt: date("2026-01-15T14:00:00Z")),
                                             secondary: nil)]
            } else {
                // 較低讀數:full 語義 = 立即下修+corrected;incremental 語義 = pending(percent 留 60)
                readings = [RateLimitReading(providerId: "codex", observedAt: date("2026-01-15T10:30:00Z"),
                                             primary: RateLimitWindowReading(usedPercent: 45, windowMinutes: 300,
                                                                             resetsAt: date("2026-01-15T14:00:00Z")),
                                             secondary: nil)]
            }
            return (AdapterRefreshResult(events: [ev0], rateLimits: readings, completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh49(c)   // round 1:ordinary,建 durable baseline 60
        rec.failSyncFile = true
        _ = runRefresh49WithFullReindex(c)   // round 2:fullReindex,45 讀數,limits commit 失敗 → pending
        rec.failSyncFile = false
        _ = runRefresh49(c)                  // round 3:ordinary —— 必須以 full 語義 replay(45 立即生效)
        let stateText = String(data: (try? Data(contentsOf: dir.appendingPathComponent("limits-state.json"))) ?? Data(),
                               encoding: .utf8) ?? ""
        // full 語義證據:corrected 立即成立且無 pendingDecrease(incremental 語義的標誌);
        // history 樣本窗保留舊 60 屬設計行為,不作禁用斷言。
        XCTAssertTrue(stateText.contains("\"corrected\":true") && !stateText.contains("pendingDecrease"),
                      "AM-4:pending fullReindex ⇒ full 語義 fold(corrected 直下修,非 pendingDecrease;state=\(stateText.prefix(400)))")
        // AM-5:再一輪(同 45 replay)⇒ .unchanged 也 clear pending + watermark 前進
        let seen3 = adapter.lastSeenState?.files.count ?? -1
        _ = runRefresh49(c)                  // round 4:.unchanged 路徑
        let seen4 = adapter.lastSeenState?.files.count ?? -1
        XCTAssertTrue(seen4 >= seen3 && seen4 > 0,
                      "AM-5:.unchanged retry 亦 clear pending、watermark 追上(round3 入參 \(seen3) → round4 入參 \(seen4))")
    }

    /// AM-6 cross-provider(injected-A):A ingest 失敗 → B 成功 durable commit ⇒ B 寫盤內容
    /// 不得含 A 的 failed 態(publish-on-commit 純度);A replay 收斂、零重複 A-transitions。
    func testAM6InjectedAFailureNotLaunderedByBCommit() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let seed = LimitEngine(stateURL: url)
        _ = seed.ingestTransitions(readings: [reading("codex", 20, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                   settings: settings, now: date("2026-01-15T10:01:00Z"))
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        rec.failSyncFile = true
        guard case .failed = e.ingest(readings: [reading("codex", 90, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                      settings: settings, now: date("2026-01-15T10:31:00Z")) else {
            XCTAssertTrue(false, "前置:A 必須 .failed"); return
        }
        rec.failSyncFile = false
        _ = e.ingestTransitions(readings: [reading("claude-code", 40, at: "2026-01-15T10:32:00Z", resetsAt: "2026-01-15T15:00:00Z")],
                                settings: settings, now: date("2026-01-15T10:33:00Z"))   // B durable commit
        let text = String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("\"percent\":90") || text.contains("\"percent\": 90"),
                       "AM-6:B 的 commit 不得夾帶 A 的 failed 90% 態")
        // A replay(同 engine)⇒ 應真正重試 barrier 並 commit(FAILED 純度下 pre==durable 20%)
        let tA = e.ingestTransitions(readings: [reading("codex", 90, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                                     settings: settings, now: date("2026-01-15T10:34:00Z"))
        XCTAssertFalse(tA.filter { self.providerOf($0) == "codex" }.isEmpty,
                       "A replay 應以 20→90 重新 fold 並交付 crossings(FAILED 純度證據)")
    }

    /// AM-7 derived 失敗不 retroactively 影響已 durable 的 ingest:watermark 保持、loud、ingest 不改判。
    func testAM7DerivedFailureDoesNotInvalidateDurableIngest() throws {
        let dir = makeTempDir()
        var round = 0
        let ev0 = UsageEvent(id: "e49c", providerId: "codex", projectId: "/p", projectName: "p", modelId: "m",
                             timestamp: date("2026-01-15T09:00:00Z"), tokens: TokenBreakdown(input: 10),
                             sourceKind: "mock")
        let adapter = MockAdapter("codex") { _ in
            round += 1
            // round 1:窗 A(已過期)→ 該輪 sweep 即處理掉;round 2+:窗 B(較新、亦過期)→
            // ingest committed(第 1 次 syncFile)後,同輪 sweep 處理 B 的 expiry(第 2 次)。
            let rs = round == 1 ? "2026-01-15T10:30:00Z" : "2026-01-15T12:30:00Z"
            let ob = round == 1 ? "2026-01-15T10:00:00Z" : "2026-01-15T12:00:00Z"
            return (AdapterRefreshResult(events: [ev0],
                                         rateLimits: [RateLimitReading(providerId: "codex",
                                                                       observedAt: date(ob),
                                                                       primary: RateLimitWindowReading(usedPercent: 60, windowMinutes: 300,
                                                                                                       resetsAt: date(rs)),
                                                                       secondary: nil)],
                                         completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh49(c)   // ingest durable 成功、watermark 推進
        let seenAfter1 = adapter.lastSeenState?.files.count ?? -1
        rec.calls.removeAll()
        rec.failSyncFileFrom = 2   // 下一輪:ingest(第 1 次 sync)成功;sweep 的 derived 寫(第 2 次)失敗
        let out2 = runRefresh49(c)
        XCTAssertTrue(out2.dashboard.dataQuality.contains { $0.contains("derived") },
                      "AM-7:derived 失敗必須 loud(dataQuality note;得到 \(out2.dashboard.dataQuality))")
        XCTAssertNil(out2.dashboard.snapshots.first { $0.providerId == "codex" }?.errorMessage,
                     "AM-7:derived 失敗不得把 provider ingest 改判為 error")
        _ = runRefresh49(c)
        let seenAfter3 = adapter.lastSeenState?.files.count ?? -1
        XCTAssertTrue(seenAfter3 > seenAfter1, "AM-7:watermark 不因 derived 失敗倒退/凍結")
    }

    /// AM-8 derivedSaveError cycle-accumulate:後續成功寫不得清掉本 cycle 較早的失敗(直到明確 cycle reset)。
    func testAM8DerivedErrorAccumulatesUntilCycleReset() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        _ = e.ingestTransitions(readings: [reading("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z"),
                                           reading("claude-code", 50, at: "2026-01-15T10:00:30Z", resetsAt: "2026-01-15T11:30:00Z")],
                                settings: settings, now: date("2026-01-15T10:05:00Z"))
        rec.failSyncFile = true
        _ = e.sweepExpiredWindows(now: date("2026-01-15T11:05:00Z"))   // codex expiry → 寫失敗
        XCTAssertNotNil(e.derivedSaveError, "前置:第一次 derived 失敗已記")
        rec.failSyncFile = false
        _ = e.sweepExpiredWindows(now: date("2026-01-15T11:35:00Z"))   // claude expiry → 寫成功
        XCTAssertNotNil(e.derivedSaveError,
                        "AM-8:同 cycle 後續成功寫不得清掉早前失敗(loud contract 失真)")
    }

    private func runRefresh49WithFullReindex(_ coord: UsageCoordinator) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await coord.refresh(fullReindex: true); sem.signal() }
        sem.wait()
        return out!
    }

    /// C-C:rollover(換窗)讀數於 recency 窗內重放 ⇒ 全程恰一次 reset 類 transition。
    /// 換窗確認機制(pending)+「亂序/重放不可自我確認」防護是受測機制。
    func testRolloverReplayWithinRecencyDoesNotRecelebrate() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url)
        // 舊窗高用量 → 新窗低用量(reset 已過)= rollover 證據;兩筆確認換窗。
        let oldW = [reading("codex", 80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T12:00:00Z")]
        let newW = [reading("codex", 3, at: "2026-01-15T12:01:00Z", resetsAt: "2026-01-15T17:00:00Z"),
                    reading("codex", 4, at: "2026-01-15T12:03:00Z", resetsAt: "2026-01-15T17:00:00Z")]
        let now = date("2026-01-15T12:05:00Z")   // reset 邊界後 5 分 < resetRecency(15 分)
        _ = e.ingestTransitions(readings: oldW, settings: settings, now: now)
        let t1 = e.ingestTransitions(readings: newW, settings: settings, now: now)
        let resets1 = t1.filter(isReset)
        // replay 整段(舊窗+新窗,recency 窗內)
        let t2a = e.ingestTransitions(readings: oldW, settings: settings, now: now)
        let t2b = e.ingestTransitions(readings: newW, settings: settings, now: now)
        let resets2 = (t2a + t2b).filter(isReset)
        XCTAssertEqual(resets2.count, 0, "recency 窗內 replay 不得重發 reset/celebration(首輪 \(resets1.count) 次,replay 得 \(resets2))")
    }
}
