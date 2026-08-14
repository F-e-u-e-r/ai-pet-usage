import Foundation
@testable import UsageCore

// MARK: - #83 A′ red-first(PLAN-v2 §5 CE1–CE4 + §3.4 restart rows + §3.3 bump 表 + R7;
// owner GO 2026-08-14)。全部先紅:stub(欄位存在、無 bump/classification)下斷言 A′ 目標行為。
// 磁碟態構造 + 全新 coordinator = crash/restart 模擬(V2C8 同模式);注入僅用既有 DurabilityOpsRecorder。

final class Limit49V3Tests: XCTestCase {

    private func rd(_ provider: String, _ percent: Double, at: String, resetsAt: String? = "2026-01-15T14:00:00Z") -> RateLimitReading {
        RateLimitReading(providerId: provider, observedAt: date(at),
                         primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300,
                                                         resetsAt: resetsAt.map(date)),
                         secondary: nil)
    }

    private func isCrossing(_ t: LimitTransition) -> Bool {
        if case .crossedThreshold = t { return true } else { return false }
    }

    private func runRefresh(_ c: UsageCoordinator, full: Bool = false) -> RefreshOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: RefreshOutcome?
        Task { out = await c.refresh(fullReindex: full); sem.signal() }
        sem.wait()
        return out!
    }

    private func limitsURL(_ dir: URL) -> URL { dir.appendingPathComponent("limits-state.json") }
    private func scanURL(_ dir: URL) -> URL { dir.appendingPathComponent("scan-state.json") }
    private func readLimits(_ dir: URL) -> [String: LimitEngine.PersistedProvider] {
        (try? AtomicJSON.readOrThrow([String: LimitEngine.PersistedProvider].self, from: limitsURL(dir))) ?? [:]
    }
    private func readScan(_ dir: URL) -> [String: ScanState] {
        (try? AtomicJSON.readOrThrow([String: ScanState].self, from: scanURL(dir))) ?? [:]
    }
    private func writeScan(_ dir: URL, _ s: [String: ScanState]) { try! AtomicJSON.write(s, to: scanURL(dir)) }
    private func writeLimits(_ dir: URL, _ s: [String: LimitEngine.PersistedProvider]) { try! AtomicJSON.write(s, to: limitsURL(dir)) }

    private func ev(_ id: String, _ pid: String) -> UsageEvent {
        UsageEvent(id: id, providerId: pid, projectId: "/p", projectName: "p", modelId: "m",
                   timestamp: date("2026-01-15T09:00:00Z"), tokens: TokenBreakdown(input: 10), sourceKind: "mock")
    }

    /// 全量歷史批(rebuildable 全檔重掃的 readings 形態):10@t0 → 85@t1(跨 warn 80)。
    private func historyBatch(_ pid: String) -> [RateLimitReading] {
        [rd(pid, 10, at: "2026-01-15T10:00:00Z"), rd(pid, 85, at: "2026-01-15T10:10:00Z")]
    }

    // MARK: engine 級 —— bump 規則表(PLAN-v2 §3.3)

    /// bump 表列 1+2:ordinary changed commit 逐次 +1;replay unchanged 不 bump、不寫 blob。
    func testV3BumpOrdinaryChangedIncrementsUnchangedDoesNot() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        guard case .committed = e.ingest(readings: [rd("codex", 40, at: "2026-01-15T09:00:00Z")],
                                         settings: CoreSettings(), now: date("2026-01-15T09:01:00Z"),
                                         reconcilingProvider: "codex") else {
            XCTAssertTrue(false, "前置:首筆 changed 必 committed"); return
        }
        XCTAssertEqual(e.reconcileGeneration(for: "codex"), 1, "首次 reconciliation 建立 generation = 1")
        guard case .committed = e.ingest(readings: [rd("codex", 55, at: "2026-01-15T09:10:00Z")],
                                         settings: CoreSettings(), now: date("2026-01-15T09:11:00Z"),
                                         reconcilingProvider: "codex") else {
            XCTAssertTrue(false, "前置:第二筆 changed 必 committed"); return
        }
        XCTAssertEqual(e.reconcileGeneration(for: "codex"), 2, "R2:changed commit 逐次推進")
        rec.calls.removeAll()
        switch e.ingest(readings: [rd("codex", 55, at: "2026-01-15T09:10:00Z")],
                        settings: CoreSettings(), now: date("2026-01-15T09:12:00Z"),
                        reconcilingProvider: "codex") {
        case .unchanged:
            XCTAssertEqual(e.reconcileGeneration(for: "codex"), 2, "replay unchanged 不推進 generation")
            XCTAssertTrue(rec.calls.isEmpty, "confirmed 下 ordinary unchanged 不重寫 blob(得到 \(rec.calls))")
        case .committed(let t): XCTAssertTrue(false, "replay 應 unchanged(得到 committed \(t))")
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        }
    }

    /// CE3 engine 半(R3):full reconciliation 即使 logical no-op 也建立新 generation,
    /// 且因 blob 已變(gen++)結果為 .committed([])(PLAN-v2 §4-e)。
    /// 情境註記(paper→code 修正):replay 同批的 full fold 必動 history/corrected ⇒ 走 changed
    /// 路徑(重爬屬 requested 語義,row-2 測試涵蓋);store==backup 的 full 實際發生於
    /// **空 readings**(全量重掃無 rate-limit 行)——R3 在此腿保證 completion identity 仍建立。
    func testV3CE3FullUnchangedStillBumpsGeneration() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url, durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: historyBatch("codex"), settings: CoreSettings(),
                                now: date("2026-01-15T10:11:00Z"), reconcilingProvider: "codex")
        XCTAssertEqual(e.reconcileGeneration(for: "codex"), 1, "前置:baseline gen=1")
        switch e.ingest(readings: [], settings: CoreSettings(), fullReindex: true,
                        now: date("2026-01-15T10:12:00Z"), reconcilingProvider: "codex") {
        case .committed(let t):
            XCTAssertEqual(t.count, 0, "no-op full:無 transitions")
            XCTAssertEqual(e.reconcileGeneration(for: "codex"), 2,
                           "R3:successful full(no-op)必須建立新 generation(failed-full 判別證據)")
        case .unchanged:
            XCTAssertTrue(false, "R3/§4-e:full 完成 gen++ ⇒ blob 已變,不得回 .unchanged")
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        }
    }

    /// CE4(R1/R2):derived write(sweep)不推進任何 generation。
    func testV3CE4DerivedWriteDoesNotAdvanceGeneration() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let e = LimitEngine(stateURL: url, durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("codex", 60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T11:00:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T10:05:00Z"),
                                reconcilingProvider: "codex")
        XCTAssertEqual(e.reconcileGeneration(for: "codex"), 1, "前置:gen=1")
        _ = e.sweepExpiredWindows(now: date("2026-01-15T11:05:00Z"))   // derived:markers 變、blob 重寫
        XCTAssertEqual(e.reconcileGeneration(for: "codex"), 1,
                       "R1/R2:derived write 重寫 blob 但不得推進 generation")
    }

    // MARK: coordinator 級 —— ack 建立與 CE1

    /// R5:refresh 成功後 scan-state ack == limits generation(且 watermark 同步 adopt)。
    func testV3AckEstablishedAfterCommit() throws {
        let dir = makeTempDir()
        let adapter = MockAdapter("codex") { _ in
            (AdapterRefreshResult(events: [self.ev("v3ack", "codex")], rateLimits: self.historyBatch("codex"),
                                  completeness: .complete),
             ScanState(files: ["r1": FileScanMark(offset: 1, size: 1)]))
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c)
        XCTAssertEqual(readLimits(dir)["codex"]?.reconcileGeneration, 1, "commit 後 gen=1")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 1, "R5:ack 於 durable commit 後建立 = gen")
        XCTAssertEqual(readScan(dir)["codex"]?.files.isEmpty, false, "watermark adopt 照舊")
    }

    /// CE1(R1 判別腿):A full pre-clear + ingest 失敗、B 同輪 commit、crash ⇒
    /// restart:A 仍 full 續跑(row 2),B 不受影響;gen[A] 未被 B 推進。
    func testV3CE1CrossProviderGeneration() throws {
        let dir = makeTempDir()
        let rec = DurabilityOpsRecorder()
        func makeA() -> MockAdapter {
            MockAdapter("pa") { _ in
                (AdapterRefreshResult(events: [self.ev("v3a", "pa")], rateLimits: self.historyBatch("pa"),
                                      completeness: .complete),
                 ScanState(files: ["a": FileScanMark(offset: 1, size: 1)]))
            }
        }
        func makeB() -> MockAdapter {
            MockAdapter("pb") { _ in
                rec.failSyncFile = false   // A 的 full ingest 已(注定)失敗;B 的 scan 先於 B 的 ingest → B 成功
                return (AdapterRefreshResult(events: [self.ev("v3b", "pb")], rateLimits: self.historyBatch("pb"),
                                             completeness: .complete),
                        ScanState(files: ["b": FileScanMark(offset: 1, size: 1)]))
            }
        }
        let settings = CoreSettings(enabledProviders: ["pa", "pb"])
        let c1 = UsageCoordinator(dataDir: dir, settings: settings,
                                  adapters: [makeA(), makeB()], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c1)   // baseline:gen[pa]=1, gen[pb]=1, acks=1
        XCTAssertEqual(readLimits(dir)["pa"]?.reconcileGeneration, 1, "前置 gen[pa]=1")
        rec.failSyncFile = true   // requested full:A(先)ingest 失敗;B 的 closure 中途解除 → B 成功
        _ = runRefresh(c1, full: true)
        let lim = readLimits(dir), scan = readScan(dir)
        XCTAssertEqual(lim["pa"]?.reconcileGeneration, 1, "R1:A 的 full 未 commit ⇒ gen[pa] 不動(B 不得推進它)")
        XCTAssertEqual(lim["pb"]?.reconcileGeneration, 2, "B 的 full commit 推進 gen[pb]")
        XCTAssertEqual(scan["pa"]?.files.isEmpty, true, "C-MF2 pre-clear durable")
        XCTAssertEqual(scan["pa"]?.ackGeneration, 1, "R4:pre-clear 保留 ack")
        XCTAssertEqual(scan["pa"]?.pendingFullReconcile, true, "R7(amended):pre-clear 豎起顯式 durable intent")
        // process death → restart(全新 coordinator;fail 已解除)
        let c2 = UsageCoordinator(dataDir: dir, settings: settings,
                                  adapters: [makeA(), makeB()], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c2)
        let lim2 = readLimits(dir), scan2 = readScan(dir)
        XCTAssertEqual(lim2["pa"]?.reconcileGeneration, 2,
                       "row 2:A 續跑 full 完成(unchanged 亦 bump,R3)⇒ gen[pa]=2")
        XCTAssertEqual(scan2["pa"]?.ackGeneration, 2, "ack 追至新 gen")
        XCTAssertEqual(scan2["pa"]?.files.isEmpty, false, "watermark 重建")
        XCTAssertEqual(lim2["pb"]?.reconcileGeneration, 2, "B ordinary replay 不再推進")
    }

    // MARK: restart rows(磁碟態構造 + 新 coordinator)

    /// 構造:兩輪 refresh(歷史 crossings 已發、gen=2)後按需覆寫磁碟態。
    /// round 1 = 全量歷史 [10,85](crossing 80 已交付);round 2 = [88@t3] changed(gen→2);
    /// round ≥3 = 全量回放 [10,85,88](restart 後的重掃形態)。
    private func makeReplayAdapter(_ pid: String) -> MockAdapter {
        var round = 0
        return MockAdapter(pid) { _ in
            round += 1
            let batch: [RateLimitReading]
            switch round {
            case 1: batch = self.historyBatch(pid)
            case 2: batch = [self.rd(pid, 88, at: "2026-01-15T10:30:00Z")]
            default: batch = self.historyBatch(pid) + [self.rd(pid, 88, at: "2026-01-15T10:30:00Z")]
            }
            return (AdapterRefreshResult(events: [self.ev("v3r\(round)", pid)], rateLimits: batch,
                                         completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
    }

    private func seedTwoRounds(_ dir: URL, _ pid: String, adapters: [MockAdapter]) {
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: [pid]),
                                 adapters: adapters, limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c)
        _ = runRefresh(c)
        XCTAssertEqual(readLimits(dir)[pid]?.reconcileGeneration, 2, "前置:兩輪 changed ⇒ gen=2")
        XCTAssertEqual(readScan(dir)[pid]?.ackGeneration, 2, "前置:ack=2")
    }

    /// row 4(owner red-first 清單「Row 6 / Sol#1」):gen=2 > ack=1 ∧ wm=∅ ⇒ ordinary replay、
    /// 零重複 transition、percent 不被歷史抬動、ack 追上、watermark 重建。Sol#1 主場景封棺。
    func testV3Row4LimitsLeadScanOrdinaryZeroDuplicate() throws {
        let dir = makeTempDir()
        seedTwoRounds(dir, "codex", adapters: [makeReplayAdapter("codex")])
        writeScan(dir, ["codex": ScanState(files: [:], ackGeneration: 1)])   // 磁碟態:pre-clear 後 full 已 commit、tail 丟
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isCrossing).count, 0,
                       "R6/row4:absence 不得進 full ⇒ 歷史 replay 全 inert,零 crossing 重發(得到 \(out.transitions))")
        let lim = readLimits(dir)["codex"]
        XCTAssertEqual(lim?.primary?.percent, 88, "I2 擋 ≤committed 的歷史讀數:percent 維持 88")
        XCTAssertFalse(lim?.primary?.corrected == true, "ordinary fold:不得標 corrected(full-exemption 未進入)")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 2, "ack 追至 gen")
        XCTAssertEqual(readScan(dir)["codex"]?.files.isEmpty, false, "watermark 重建")
    }

    /// row 7:gen=2 ∧ ack 缺席(scan-state 整檔遺失)⇒ ordinary 全檔重掃、無歷史 transition 重發、
    /// ack 建立 = 現值 gen。owner 語義:full source scan ≠ full-reindex fold semantics。
    func testV3Row7ScanStateLossOrdinaryNoHistoricalReplay() throws {
        let dir = makeTempDir()
        seedTwoRounds(dir, "codex", adapters: [makeReplayAdapter("codex")])
        try FileManager.default.removeItem(at: scanURL(dir))   // 磁碟態:scan-state 遺失(ack 與 wm 皆缺)
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isCrossing).count, 0,
                       "row7:gen 存在 ⇒ 歷史 crossings 已發過,重掃必須 ordinary fold,零重發(得到 \(out.transitions))")
        let lim = readLimits(dir)["codex"]
        XCTAssertEqual(lim?.primary?.percent, 88, "I2 擋歷史:percent 不回捲")
        XCTAssertFalse(lim?.primary?.corrected == true, "不得進 full-exemption")
        XCTAssertEqual(lim?.reconcileGeneration, 2, "unchanged 重掃不 bump")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 2, "ack 重建 = 現值 gen")
    }

    /// row 2:R7(amended)顯式 durable intent(pendingFullReconcile ∧ ack==gen)⇒ restart 續跑
    /// FULL 語義(較新的下修讀數被 corrected 直接採用,非 pendingDecrease 兩筆確認)。
    func testV3Row2ReservedShapeResumesFullSemantics() throws {
        let dir = makeTempDir()
        var round = 0
        func makeAdapter() -> MockAdapter {
            MockAdapter("codex") { _ in
                round += 1
                let batch = round == 1 ? [self.rd("codex", 60, at: "2026-01-15T10:00:00Z")]
                                       : [self.rd("codex", 45, at: "2026-01-15T10:30:00Z")]
                return (AdapterRefreshResult(events: [self.ev("v3row2-\(round)", "codex")], rateLimits: batch,
                                             completeness: .complete),
                        ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
            }
        }
        let c1 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeAdapter()], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c1)   // baseline 60,gen=1, ack=1
        writeScan(dir, ["codex": ScanState(files: [:], ackGeneration: 1,
                                           pendingFullReconcile: true)])   // R4 pre-clear 態:durable intent、未 commit
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeAdapter()], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c2)   // 45@t2(較新、較低)
        let lim = readLimits(dir)["codex"]
        XCTAssertEqual(lim?.primary?.corrected, true,
                       "row2:durable intent ⇒ full fold 語義續跑(corrected 直下修,非 pendingDecrease)")
        XCTAssertEqual(lim?.primary?.percent, 45)
        XCTAssertEqual(lim?.reconcileGeneration, 2, "full 完成 ⇒ gen++")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 2, "ack 追至新 gen")
    }

    /// row 8(owner POISON verdict):gen 缺席 ∧ ack 存在 ⇒ loud fail-closed——該 provider 本輪
    /// 完全 skip:無 limits 建立、watermark 不動、無 events 落帳、無自動 identity reset。
    func testV3Row8PoisonGenAbsentAckPresent() throws {
        let dir = makeTempDir()
        writeLimits(dir, [:])   // limits 遺失/重建:無任何 provider record
        writeScan(dir, ["codex": ScanState(files: ["old": FileScanMark(offset: 9, size: 9)], ackGeneration: 5)])
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c)
        XCTAssertEqual(out.insertedEvents, 0, "poison:provider 本輪 skip,不落任何 events")
        XCTAssertNil(readLimits(dir)["codex"], "poison:不得自動建立/重置 limits identity")
        let scan = readScan(dir)["codex"]
        XCTAssertEqual(scan?.ackGeneration, 5, "poison:scan-state 原樣保留(證據不清洗)")
        XCTAssertEqual(scan?.files["old"]?.offset, 9, "poison:watermark 不得推進")
    }

    /// row 5(R6 前半):gen=1 < ack=5 ⇒ 同 row 8 fail-closed 行為。
    func testV3Row5PoisonGenLessThanAck() throws {
        let dir = makeTempDir()
        let seed = MockAdapter("codex") { _ in
            (AdapterRefreshResult(events: [self.ev("v3row5", "codex")], rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z")],
                                  completeness: .complete),
             ScanState(files: ["r1": FileScanMark(offset: 1, size: 1)]))
        }
        let c1 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [seed], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c1)   // gen=1
        var scan = readScan(dir)
        scan["codex"]?.ackGeneration = 5   // 外力回退 limits 的等價磁碟態:ack 超前
        writeScan(dir, scan)
        let before = readLimits(dir)["codex"]
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.insertedEvents, 0, "poison:skip 全部寫入")
        XCTAssertEqual(readLimits(dir)["codex"], before, "poison:limits 原樣(不 ingest)")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 5, "poison:不清洗 ack")
    }

    // MARK: R7(amended)durable intent 守護 ×3

    /// R7 腿 1:explicit full pre-clear(ingest 失敗凍結於 intent 態)恰好豎起 durable intent。
    func testV3R7PreClearProducesReservedShape() throws {
        let dir = makeTempDir()
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c)   // gen=1, ack=1, wm=r1
        rec.failSyncFile = true
        _ = runRefresh(c, full: true)   // pre-clear durable;full ingest 失敗 → 凍結於 intent 態
        let scan = readScan(dir)["codex"]
        let gen = readLimits(dir)["codex"]?.reconcileGeneration
        XCTAssertEqual(scan?.files.isEmpty, true, "pre-clear:watermark 空")
        XCTAssertEqual(gen, 1, "full 未 commit:gen 不動")
        XCTAssertEqual(scan?.ackGeneration, gen, "R4:pre-clear 保留 ack")
        XCTAssertEqual(scan?.pendingFullReconcile, true, "R7:pre-clear = intent 的唯一寫出點")
    }

    /// R7 腿 2:ordinary 路徑(增量 changed/unchanged 系列)永不意外豎起 intent。
    func testV3R7OrdinaryPathsNeverManufactureReservedShape() throws {
        let dir = makeTempDir()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        for _ in 0..<4 {   // changed、changed、unchanged replay、unchanged replay
            _ = runRefresh(c)
            XCTAssertFalse(readScan(dir)["codex"]?.pendingFullReconcile == true,
                           "R7:ordinary 路徑不得豎起 durable full intent")
        }
    }

    /// R7 腿 3(shape-collision regression;原 shape-encoding 的 falsifier):adapter 正常成功但
    /// watermark 天然為空(空目錄/零檔案 provider)⇒ ack==gen ∧ wm=∅ 自然成立——不得因此
    /// 誤判 resumeFull(誤判會令下一輪 full rescan + retention cutoff 清史)。
    func testV3R7NaturallyEmptyWatermarkDoesNotTriggerResumeFull() throws {
        let dir = makeTempDir()
        var rounds = 0
        let adapter = MockAdapter("codex") { state in
            rounds += 1
            return (AdapterRefreshResult(events: [self.ev("v3empty\(rounds)", "codex")],
                                         rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z")],
                                         completeness: .complete),
                    state)   // 天然空 watermark:adapter 從不建立 files
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let o1 = runRefresh(c)
        XCTAssertEqual(o1.insertedEvents, 1, "前置:首輪 append 成功")
        let scan = readScan(dir)["codex"]
        XCTAssertEqual(scan?.files.isEmpty, true, "前置:wm 天然空")
        XCTAssertEqual(scan?.ackGeneration, readLimits(dir)["codex"]?.reconcileGeneration, "前置:ack==gen")
        let o2 = runRefresh(c)   // 舊 shape-encoding 在此誤判 resumeFull → replace/清史
        XCTAssertEqual(o2.insertedEvents, 1, "第二輪仍是 ordinary append(id 去重後 1 筆新),非 full replace")
        XCTAssertEqual(o2.providerOutcomes.isEmpty, true, "增量刷新:providerOutcomes 空(未走 full 分支)")
    }

    // MARK: migration(row 6′)

    /// legacy(無 gen 無 ack、wm present)⇒ ordinary 照舊;首個 reconciliation(unchanged replay)
    /// 經 proto-I1 no-op barrier 同時建立 gen 與 ack;watermark 在建立前不因 unchanged 前進由
    /// proto-I1 .failed 腿保證(注入負腿)。
    func testV3MigrationLazyEstablishmentOnFirstReconciliation() throws {
        let dir = makeTempDir()
        seedTwoRounds(dir, "codex", adapters: [makeReplayAdapter("codex")])
        // strip 成 legacy 磁碟態:limits 無 gen、scan 無 ack(wm 保留)
        var lim = readLimits(dir); lim["codex"]?.reconcileGeneration = nil; writeLimits(dir, lim)
        var scan = readScan(dir); scan["codex"]?.ackGeneration = nil; writeScan(dir, scan)
        let wmBefore = scan["codex"]?.files
        // 負腿:barrier 失敗 ⇒ gen 未建立、watermark 不得前進
        let recFail = DurabilityOpsRecorder(); recFail.failSyncFile = true
        let cF = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: recFail.ops)
        _ = runRefresh(cF)
        XCTAssertNil(readLimits(dir)["codex"]?.reconcileGeneration, "負腿:barrier 失敗 ⇒ identity 未建立")
        XCTAssertEqual(readScan(dir)["codex"]?.files, wmBefore, "負腿:identity 未建立 ⇒ watermark 不前進")
        // 正腿:unchanged replay 經 no-op confirm 建立 identity
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isCrossing).count, 0, "migration 不重發")
        XCTAssertEqual(readLimits(dir)["codex"]?.reconcileGeneration, 1,
                       "migration:首個 reconciliation(unchanged)建立 gen=1(與 proto-I1 confirm 同 barrier)")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 1, "ack 隨建立")
    }

    // MARK: #83 preregistered acceptance — G1 / G2(r3 ACCEPT findings,A′ implementation 必含)

    /// G1:reload 保 confirmed(raw bytes 相同)但 sanitize 改動 store ⇒ confirmation 必須失效,
    /// 下一個 would-be-.unchanged 必須補 barrier(否則 sanitized 內容未 durable 而 watermark 前進)。
    func testV3G1SanitizeInvalidatesDurabilityConfirmation() {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("limits.json")
        let rec = DurabilityOpsRecorder()
        let e = LimitEngine(stateURL: url, durabilityOps: rec.ops)
        // commit 一筆錯置窗(primary.windowMinutes=999——歷史遷移殘留形態)⇒ confirmed blob 含它。
        let misplaced = RateLimitReading(providerId: "codex", observedAt: date("2026-01-15T10:00:00Z"),
                                         primary: RateLimitWindowReading(usedPercent: 50, windowMinutes: 999,
                                                                         resetsAt: date("2026-01-15T14:00:00Z")),
                                         secondary: nil)
        guard case .committed = e.ingest(readings: [misplaced], settings: CoreSettings(),
                                         now: date("2026-01-15T10:01:00Z")) else {
            XCTAssertTrue(false, "前置:錯置窗 commit"); return
        }
        e.reloadFromDisk()   // raw == confirmedStateBlob ⇒ 保 confirmed;sanitize 清掉錯置 primary ⇒ store 偏離磁碟
        rec.calls.removeAll()
        switch e.ingest(readings: [], settings: CoreSettings(), now: date("2026-01-15T10:02:00Z")) {
        case .unchanged:
            XCTAssertTrue(rec.calls.contains("syncFile") && rec.calls.contains("syncDirectory"),
                          "G1:sanitize 改動後 confirmation 必須失效 ⇒ .unchanged 前補完整 barrier(得到 \(rec.calls))")
        case .committed: XCTAssertTrue(rec.calls.contains("syncFile"), "committed 亦可,barrier 必須真跑")
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        }
    }

    /// G2 正腿:estimated reset 已**交付**(非僅 handled)後,同一 logical boundary 的遲到 official
    /// 窗到期不得再發——同 boundary 只有一個 delivery identity(讀側統一)。
    func testV3G2EstimatedDeliveredSuppressesLateOfficialSameBoundary() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        // official 窗(resetsAt 17:58)先入;estimated block(end 18:00)同一 logical boundary
        //(|end−resetsAt| = 2min ≤ recency)。事件持續到 17:59(> resetsAt、觀測 stale > 60s)
        // ⇒ hasUsableWindow=false ⇒ estimated 得以交付(SEV1 的真實形態)。
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-15T17:00:00Z",
                                              resetsAt: "2026-01-15T17:58:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                 now: date("2026-01-15T17:59:30Z"))
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                        now: date("2026-01-15T18:05:00Z"))
        XCTAssertEqual(tEst.filter(isReset).count, 1, "前置:estimated reset 已交付")
        // 遲到 official 到期(17:58 < 18:06,recency 內)⇒ 同 boundary 不得再發。
        let tOff = e.sweepExpiredWindows(now: date("2026-01-15T18:06:00Z"))
        XCTAssertEqual(tOff.filter(isReset).count, 0,
                       "G2:estimated 已交付 ⇒ 同 boundary 的 official sweep 不得雙發(得到 \(tOff))")
    }

    /// G2 反腿:estimated 僅被閘壓下(handled 但**未交付**)⇒ 新鮮的 official 到期必須照發
    ///(不得因 handled 誤吞唯一一次通知)。
    func testV3G2SuppressedEstimatedDoesNotSwallowFreshOfficial() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-15T17:00:00Z",
                                              resetsAt: "2026-01-15T18:10:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:50:00Z"),
                                 now: date("2026-01-15T17:55:00Z"))
        // app 睡過邊界:18:20 才處理(> recency 15min)⇒ estimated 壓下(handled、未交付)。
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:50:00Z"),
                                        now: date("2026-01-15T18:20:00Z"))
        XCTAssertEqual(tEst.filter(isReset).count, 0, "前置:estimated 被新鮮度閘壓下")
        // official(18:10)在 18:20 到期處理:recency 內 ⇒ 必須照發(唯一一次)。
        let tOff = e.sweepExpiredWindows(now: date("2026-01-15T18:20:30Z"))
        XCTAssertEqual(tOff.filter(isReset).count, 1,
                       "G2 反腿:estimated 未交付 ⇒ official 不得被誤吞(得到 \(tOff))")
    }

    private func isReset(_ t: LimitTransition) -> Bool { if case .reset = t { return true } else { return false } }

    // MARK: xcheck-r1 bounded clearing(U1–U5 + intent∧gen>ack;owner 授權 2026-08-14)

    /// U1(D2 gating):row-2 resume 輪(非 requested)完成 full——providerOutcomes 必須維持
    /// #48 §7「增量為空」,揭示改走 loud quality note;requested 輪照舊填寫。
    func testV3U1ResumeFullKeepsOutcomesEmptyAndLoud() throws {
        let dir = makeTempDir()
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c)                    // gen=1, ack=1
        rec.failSyncFile = true
        let oFail = runRefresh(c, full: true)   // requested full 失敗:intent 凍結
        // W5 twin(clearing-2,owner contract):requested-full 的 limits fold 失敗 ⇒ 不得產生
        // 看似成功的 outcome——rebuildable 的 .replaced-on-fail 與 cumulative 同律 ⇒ omit
        //(errors/notes 承載 failure;attemptedThisRound 防 notAttempted 誤標)。
        XCTAssertEqual(oFail.providerOutcomes.isEmpty, true,
                       "W5 twin:requested-fail 輪 outcome 缺席(得到 \(oFail.providerOutcomes))")
        XCTAssertNotNil(oFail.dashboard.dataQuality.first { $0.contains("will resume next refresh") },
                        "failure 揭示由 note 承載")
        rec.failSyncFile = false
        let oResume = runRefresh(c)          // row-2 resume(fullReindex=false)
        XCTAssertEqual(oResume.providerOutcomes.isEmpty, true,
                       "U1/D2:resume 輪不得污染增量 outcome contract(得到 \(oResume.providerOutcomes))")
        XCTAssertTrue(oResume.dashboard.dataQuality.contains { $0.contains("resume") || $0.contains("resumed") },
                      "U1:resume 完成必須 loud(quality note;得到 \(oResume.dashboard.dataQuality))")
        XCTAssertEqual(readScan(dir)["codex"]?.pendingFullReconcile, nil, "resume 成功清 intent")
    }

    /// U1(row 7 loud):scan-state 遺失而 limits 歷史存在——ordinary 重掃之外必須 loud 揭示。
    func testV3U1Row7EmitsLoudQualityNote() throws {
        let dir = makeTempDir()
        seedTwoRounds(dir, "codex", adapters: [makeReplayAdapter("codex")])
        try FileManager.default.removeItem(at: scanURL(dir))
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("row 7") },
                      "U1:row 7 必須 loud(得到 \(out.dashboard.dataQuality))")
    }

    /// U2(poison 完全 fail-closed):poisoned provider 必須也被排除於 refresh 尾的全域
    /// sweep / estimated 派生寫入——不得寫 marker、不得交付 reset。
    /// coordinator 的 refresh 無 now 注入面 ⇒ sweep 可交付窗以磁碟態構造:
    /// 「(真實 now 的)60 秒前過期、recency 內、percent≥30、未 handled」。
    func testV3U2PoisonExcludedFromDerivedPasses() throws {
        let dir = makeTempDir()
        let seed = MockAdapter("codex") { _ in
            (AdapterRefreshResult(events: [self.ev("v3u2", "codex")],
                                  rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z",
                                                       resetsAt: "2026-01-15T14:00:00Z")],
                                  completeness: .complete),
             ScanState(files: ["r1": FileScanMark(offset: 1, size: 1)]))
        }
        let c1 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [seed], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c1)   // gen=1(c1 的 sweep 已把 2026-01 窗標 handled——無妨,下面整個重寫)
        var lim = readLimits(dir)
        lim["codex"]?.primary?.resetsAt = Date(timeIntervalSinceNow: -60)   // 剛過期(recency 內)
        lim["codex"]?.primary?.expiryHandled = false                        // sweep 可交付形態
        lim["codex"]?.primary?.percent = 60
        writeLimits(dir, lim)
        var scan = readScan(dir); scan["codex"]?.ackGeneration = 9; writeScan(dir, scan)   // poison(row 5)
        let limBefore = readLimits(dir)["codex"]
        let idle = MockAdapter("codex") { state in
            (AdapterRefreshResult(events: [], rateLimits: [], completeness: .complete), state)
        }
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [idle], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isReset).count, 0,
                       "U2:poisoned provider 不得由 sweep 交付 reset(得到 \(out.transitions))")
        XCTAssertEqual(readLimits(dir)["codex"], limBefore,
                       "U2:poisoned provider 的 limits record 不得被任何派生寫入改動(含 expiryHandled)")
    }

    /// U3(shared boundary predicate):estimated 已交付後,fold 的換窗路徑(非 sweep)收到
    /// 官方新窗讀數——同 logical boundary 不得再發 official reset。
    func testV3U3FoldRolloverSuppressedAfterEstimatedDelivery() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        // 同 G2 正腿佈置:official 17:58 窗 60%、estimated end 18:00 於 18:05 交付。
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-15T17:00:00Z",
                                              resetsAt: "2026-01-15T17:58:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                 now: date("2026-01-15T17:59:30Z"))
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                        now: date("2026-01-15T18:05:00Z"))
        XCTAssertEqual(tEst.filter(isReset).count, 1, "前置:estimated 已交付")
        // 官方新窗讀數(5%@18:06,resetsAt 22:58)→ fold 換窗接管路徑(舊窗 17:58 已過期,
        // incumbent 不可證存活)→ 現行在 fold 內發 official reset = 同 boundary 雙發。
        let tFold = e.ingestTransitions(readings: [rd("claude-code", 5, at: "2026-01-15T18:06:00Z",
                                                      resetsAt: "2026-01-15T22:58:00Z")],
                                        settings: CoreSettings(), now: date("2026-01-15T18:06:30Z"))
        XCTAssertEqual(tFold.filter(isReset).count, 0,
                       "U3:同 boundary 已由 estimated 交付 ⇒ fold 換窗不得再發 official(得到 \(tFold))")
    }

    /// U3 反腿:estimated 僅 suppressed(未交付)⇒ fold 換窗的合法 official reset 照發。
    func testV3U3FoldRolloverStillFiresWhenEstimatedSuppressed() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-15T17:00:00Z",
                                              resetsAt: "2026-01-15T17:58:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                 now: date("2026-01-15T17:59:30Z"))
        // 睡過邊界 → 18:20 處理 → suppressed(handled,未交付)。
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                        now: date("2026-01-15T18:20:00Z"))
        XCTAssertEqual(tEst.filter(isReset).count, 0, "前置:estimated suppressed")
        // 官方新窗讀數(5%@18:06,於 18:06:30 進批;rolloverIsFresh 對 now−observedAt ≤ recency 成立)
        // ⇒ 沒有 delivered 記錄,不得誤吞。
        let tFold = e.ingestTransitions(readings: [rd("claude-code", 5, at: "2026-01-15T18:06:00Z",
                                                      resetsAt: "2026-01-15T22:58:00Z")],
                                        settings: CoreSettings(), now: date("2026-01-15T18:06:30Z"))
        XCTAssertEqual(tFold.filter(isReset).count, 1,
                       "U3 反腿:未交付 ⇒ fold 換窗 official 照發(得到 \(tFold))")
    }

    /// U4(first authoritative construction → full fold):first contact 的 decrease-ending
    /// 歷史 [60@t1, 45@t2] 必須得到 45(corrected),不得停在 60 + pendingDecrease。
    func testV3U4FirstContactUsesFullFold() throws {
        let dir = makeTempDir()
        let adapter = MockAdapter("codex") { _ in
            (AdapterRefreshResult(events: [self.ev("v3u4", "codex")],
                                  rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z"),
                                               self.rd("codex", 45, at: "2026-01-15T10:30:00Z")],
                                  completeness: .complete),
             ScanState(files: ["r1": FileScanMark(offset: 1, size: 1)]))
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c)
        let lim = readLimits(dir)["codex"]
        XCTAssertEqual(lim?.primary?.percent, 45,
                       "U4:first contact 用 full fold ⇒ decrease-ending 歷史直接收斂 45")
        XCTAssertEqual(lim?.primary?.pendingDecrease == nil, true, "U4:不得掛 pendingDecrease")
        XCTAssertEqual(lim?.reconcileGeneration, 1, "首次建立 identity")
    }

    /// U5(bump 粒度):reconciling 主體 A 的批次混入他 provider 讀數(contract-violation 防禦域)
    /// ——A 的 slice 未變 ⇒ gen[A] 不得因 whole-store 變化被推進;B 非主體亦不得推進。
    func testV3U5CrossProviderReadingDoesNotBumpSubject() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("pa", 40, at: "2026-01-15T09:00:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T09:01:00Z"),
                                reconcilingProvider: "pa")
        XCTAssertEqual(e.reconcileGeneration(for: "pa"), 1, "前置:gen[pa]=1")
        // 主體 pa、readings 只含 pb ⇒ pa slice 不變、pb slice 變(落盤如實)。
        switch e.ingest(readings: [rd("pb", 60, at: "2026-01-15T09:10:00Z")],
                        settings: CoreSettings(), now: date("2026-01-15T09:11:00Z"),
                        reconcilingProvider: "pa") {
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        default: break
        }
        XCTAssertEqual(e.reconcileGeneration(for: "pa"), 1,
                       "U5:主體 slice 未變 ⇒ gen[pa] 不得被他 provider 的變化帶著 bump")
        XCTAssertNil(e.reconcileGeneration(for: "pb"), "pb 非主體 ⇒ 不建立/不推進")
    }

    /// grok-NIT regression:pendingFullReconcile ∧ gen>ack ⇒ generation evidence 優先——
    /// ordinary recovery,成功後清 pending;intent bit 不得壓過 limits-lead 的 durable fact。
    func testV3IntentWithGenLeadTakesOrdinaryAndClears() throws {
        let dir = makeTempDir()
        seedTwoRounds(dir, "codex", adapters: [makeReplayAdapter("codex")])
        writeScan(dir, ["codex": ScanState(files: [:], ackGeneration: 1,
                                           pendingFullReconcile: true)])   // 磁碟態:commit 成功、tail 丟、intent 殘留
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                  adapters: [makeReplayAdapter("codex")], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isCrossing).count, 0, "ordinary:零重發")
        let lim = readLimits(dir)["codex"]
        XCTAssertFalse(lim?.primary?.corrected == true, "intent∧gen>ack ⇒ 不得進 full 語義")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 2, "ack 追至 gen")
        XCTAssertEqual(readScan(dir)["codex"]?.pendingFullReconcile, nil, "成功 adopt 清 intent")
    }

    // MARK: clearing-2 counterlegs(W1–W5;owner 授權 2026-08-14 最後一輪 bounded clearing)

    /// CL1(W1):poisoned ∧ 暫時 unavailable 的 provider 仍必須被 pre-pass 排除——
    /// sweep 與 estimated 派生 pass 皆不得寫入/交付。
    func testV3W1UnavailablePoisonedStillExcludedFromDerivedPasses() throws {
        let dir = makeTempDir()
        let seed = MockAdapter("claude-code") { _ in
            (AdapterRefreshResult(events: [self.ev("v3w1", "claude-code")],
                                  rateLimits: [self.rd("claude-code", 60, at: "2026-01-15T10:00:00Z",
                                                       resetsAt: "2026-01-15T14:00:00Z")],
                                  completeness: .complete),
             ScanState(files: ["r1": FileScanMark(offset: 1, size: 1)]))
        }
        let c1 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["claude-code"]),
                                  adapters: [seed], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c1)   // gen=1
        // 磁碟構造:sweep 可交付窗(剛過期、未 handled)+ estimated 可交付 block(過期 recency 內、
        // 未 handled)+ poison(ack 超前)。
        var lim = readLimits(dir)
        lim["claude-code"]?.primary?.resetsAt = Date(timeIntervalSinceNow: -60)
        lim["claude-code"]?.primary?.expiryHandled = false
        lim["claude-code"]?.primary?.percent = 60
        lim["claude-code"]?.estimatedBlockEnd = Date(timeIntervalSinceNow: -90)
        lim["claude-code"]?.estimatedBlockTokens = 500
        lim["claude-code"]?.estimatedResetHandled = false
        writeLimits(dir, lim)
        var scan = readScan(dir); scan["claude-code"]?.ackGeneration = 9; writeScan(dir, scan)
        let limBefore = readLimits(dir)["claude-code"]
        let idle = MockAdapter("claude-code") { state in
            (AdapterRefreshResult(events: [], rateLimits: [], completeness: .complete), state)
        }
        idle.availabilityOverride = ProviderAvailability(available: false, detail: "mock offline")   // W1 核心
        let c2 = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["claude-code"]),
                                  adapters: [idle], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c2)
        XCTAssertEqual(out.transitions.filter(isReset).count, 0,
                       "W1:unavailable∧poisoned 仍須排除於 sweep/estimated(得到 \(out.transitions))")
        XCTAssertEqual(readLimits(dir)["claude-code"], limBefore,
                       "W1:poisoned provider 的 limits record 一 byte 不得動")
    }

    /// CL2(W2)正腿:雙 nil-resetsAt 的 official rollover,在 estimated 已交付同一 logical reset
    ///(observedAt 距 deliveredAt ≤ recency)後不得再發。15 分鐘窗維持(owner)。
    func testV3W2NilBoundaryRolloverSuppressedAfterEstimatedDelivery() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        // nil-resetsAt 官方窗(60%),觀測已 25h 舊 ⇒ hasUsableWindow=false ⇒ estimated 可交付。
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-14T17:00:00Z", resetsAt: nil)],
                                settings: CoreSettings(), now: date("2026-01-14T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                 now: date("2026-01-15T17:59:30Z"))
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                        now: date("2026-01-15T18:05:00Z"))
        XCTAssertEqual(tEst.filter(isReset).count, 1, "前置:estimated 交付(官方 nil 窗 25h 舊不 usable)")
        // 官方雙 nil rollover(60→5)於 18:06 觀測:距 deliveredAt(18:00)6min ≤ recency ⇒ 同一 reset。
        let tRoll = e.ingestTransitions(readings: [rd("claude-code", 5, at: "2026-01-15T18:06:00Z", resetsAt: nil)],
                                        settings: CoreSettings(), now: date("2026-01-15T18:06:30Z"))
        XCTAssertEqual(tRoll.filter(isReset).count, 0,
                       "W2:nil-boundary rollover 需以 observedAt↔deliveredAt recency 判同一 reset(得到 \(tRoll))")
    }

    /// CL2(W2)反腿:estimated 僅 handled(未交付)⇒ 官方 nil rollover 照發,不得誤吞。
    func testV3W2NilBoundaryRolloverFiresWhenEstimatedSuppressed() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("claude-code", 60, at: "2026-01-14T17:00:00Z", resetsAt: nil)],
                                settings: CoreSettings(), now: date("2026-01-14T17:01:00Z"))
        _ = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                 blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                 now: date("2026-01-15T17:59:30Z"))
        let tEst = e.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T18:00:00Z"),
                                        blockTokens: 500, lastEventAt: date("2026-01-15T17:59:00Z"),
                                        now: date("2026-01-15T18:20:00Z"))   // 睡過邊界 ⇒ suppressed
        XCTAssertEqual(tEst.filter(isReset).count, 0, "前置:estimated suppressed(handled 未交付)")
        let tRoll = e.ingestTransitions(readings: [rd("claude-code", 5, at: "2026-01-15T18:06:00Z", resetsAt: nil)],
                                        settings: CoreSettings(), now: date("2026-01-15T18:06:30Z"))
        XCTAssertEqual(tRoll.filter(isReset).count, 1,
                       "W2 反腿:未交付 ⇒ 官方 nil rollover 照發(得到 \(tRoll))")
    }

    /// CL3(W3):A first-contact 的 full 豁免必須 provider-scoped——同批混入 established B 的
    /// stale 低讀數(observedAt ≤ B committed)不得繞過 B 的 temporal authority。
    func testV3W3FullExemptionScopedToReconcilingProvider() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: limitsURL(dir),
                            durabilityOps: DurabilityOpsRecorder().ops)
        _ = e.ingestTransitions(readings: [rd("pb", 85, at: "2026-01-15T10:00:00Z")],
                                settings: CoreSettings(), now: date("2026-01-15T10:01:00Z"),
                                reconcilingProvider: "pb")   // B established:85 @10:00
        // A first-contact full;批混入 B 的 stale 10@09:00(contract-violation 防禦域)。
        let t = e.ingestTransitions(readings: [rd("pa", 50, at: "2026-01-15T10:05:00Z"),
                                               rd("pb", 10, at: "2026-01-15T09:00:00Z")],
                                    settings: CoreSettings(), fullReindex: true,
                                    now: date("2026-01-15T10:06:00Z"), reconcilingProvider: "pa")
        XCTAssertEqual(t.filter { if case .crossedThreshold(let p, _, _, _) = $0 { return p == "pb" } else { return false } }.count, 0,
                       "W3:B 不得因同批而重放 crossings")
        let lim = readLimits(dir)
        XCTAssertEqual(lim["pb"]?.primary?.percent, 85,
                       "W3:B 的 stale 讀數必須被 temporal authority 擋下(full 豁免只屬主體 A)")
        XCTAssertEqual(lim["pa"]?.primary?.percent, 50, "A 主體照 full 採用")
    }

    /// CL4(W4):gen[A]=nil ∧ A 無自身變化 ∧ 批含 B 的 changed 讀數 ⇒ A 的 identity 仍必須建立
    ///(establish 獨立於 reading mutation);B 非主體不得建立。
    func testV3W4EstablishmentIndependentOfUnrelatedMutation() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"),
                            durabilityOps: DurabilityOpsRecorder().ops)
        // 主體 A、批只含 B 的 changed 讀數(防禦域):whole-store changed、A slice 不變。
        switch e.ingest(readings: [rd("pb", 60, at: "2026-01-15T09:10:00Z")],
                        settings: CoreSettings(), now: date("2026-01-15T09:11:00Z"),
                        reconcilingProvider: "pa") {
        case .failed(let err): XCTAssertTrue(false, "\(err)")
        default: break
        }
        XCTAssertEqual(e.reconcileGeneration(for: "pa"), 1,
                       "W4:gen 缺席的主體必須在本次 durable commit 建立 identity(不得讓 watermark 先於 identity)")
        XCTAssertNil(e.reconcileGeneration(for: "pb"), "B 非主體 ⇒ 不建立")
    }

    /// CL5(W5):cumulative requested full——ledger append 成功、limits fold 失敗 ⇒
    /// providerOutcomes 不得有任何 entry(owner:omit,絕不 .appendedCumulative 成功樣;
    /// 亦不得被迴圈尾誤標 .notAttempted),loud error/note 必在。
    func testV3W5CumulativeFailedFoldOmitsSuccessOutcome() throws {
        let dir = makeTempDir()
        var round = 0
        let adapter = MockAdapter("codex", historyModel: .cumulativeSnapshotOnly) { _ in
            round += 1
            let pct: Double = round == 1 ? 60 : 45
            let ob = round == 1 ? "2026-01-15T10:00:00Z" : "2026-01-15T10:30:00Z"
            return (AdapterRefreshResult(events: [self.ev("v3w5-\(round)", "codex")],
                                         rateLimits: [self.rd("codex", pct, at: ob)],
                                         completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c)                    // baseline 60
        rec.failSyncFile = true
        let out = runRefresh(c, full: true)  // requested full:append 成功、limits fold 失敗
        XCTAssertNil(out.providerOutcomes["codex"],
                     "W5:limits 失敗 ⇒ 該 provider outcome 必須完全缺席(得到 \(String(describing: out.providerOutcomes["codex"])))")
        XCTAssertNotNil(out.dashboard.limitStates, "smoke")   // outcome 缺席不影響 dashboard 組裝
        XCTAssertTrue(out.dashboard.dataQuality.contains { $0.contains("re-run reindex") },
                      "W5:loud note 必在(得到 \(out.dashboard.dataQuality))")
    }

    /// CL6(U1 counterleg,判別力):resume 輪的 **非 .replaced** 腿(incomplete)同樣受 gating——
    /// outcomes 空、note 照發。revert 任一 preserve/incomplete 呼叫點的 gating 會使本測紅。
    func testV3U1ResumeIncompleteLegAlsoGated() throws {
        let dir = makeTempDir()
        var round = 0
        let adapter = MockAdapter("codex") { _ in
            round += 1
            let completeness: ScanCompleteness = round >= 3 ? .incomplete("mock partial") : .complete
            return (AdapterRefreshResult(events: [self.ev("v3cl6-\(round)", "codex")],
                                         rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z")],
                                         completeness: completeness),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c)                    // r1 baseline(gen=1)
        rec.failSyncFile = true
        _ = runRefresh(c, full: true)        // r2 requested full 失敗 → intent 凍結
        rec.failSyncFile = false
        let oResume = runRefresh(c)          // r3 resume;adapter 回 .incomplete → preservedIncomplete 腿
        XCTAssertEqual(oResume.providerOutcomes.isEmpty, true,
                       "CL6:resume 輪的 incomplete 腿亦不得填 outcomes(得到 \(oResume.providerOutcomes))")
        XCTAssertTrue(oResume.dashboard.dataQuality.contains { $0.contains("reindex incomplete") },
                      "CL6:incomplete 的既有 loud note 照發")
    }

    // MARK: tiny final correction(X1/X2/X3;owner final verdict 2026-08-14)

    /// X1:availability flap(preflight unavailable → 主迴圈 available)下 provider 真正 attempt
    /// 後 limits fold 失敗——preflight 的 stale `.preservedUnavailable` prefill 必須被清除,
    /// 不得對 attempted-but-failed provider 留下 preserved/success-looking outcome(W5 contract)。
    func testV3X1AvailabilityFlapClearsStalePreservedUnavailable() throws {
        let dir = makeTempDir()
        var round = 0
        let adapter = MockAdapter("codex") { _ in
            round += 1
            return (AdapterRefreshResult(events: [self.ev("v3x1-\(round)", "codex")],
                                         rateLimits: [self.rd("codex", round == 1 ? 60 : 45,
                                                              at: round == 1 ? "2026-01-15T10:00:00Z" : "2026-01-15T10:30:00Z")],
                                         completeness: .complete),
                    ScanState(files: ["r\(round)": FileScanMark(offset: Int64(round), size: 1)]))
        }
        let rec = DurabilityOpsRecorder()
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: rec.ops)
        _ = runRefresh(c)   // baseline(gen=1)
        // requested full 輪:preflight 探測 unavailable(prefill .preservedUnavailable)、
        // 主迴圈 guard 探測 available(真正 attempt)→ limits fold 失敗。
        adapter.availabilitySequence = [ProviderAvailability(available: false, detail: "flap-preflight"),
                                        ProviderAvailability(available: true, detail: "flap-mainloop")]
        rec.failSyncFile = true
        let out = runRefresh(c, full: true)
        XCTAssertNil(out.providerOutcomes["codex"],
                     "X1:attempted-but-failed 不得殘留 preflight 的 .preservedUnavailable(得到 \(String(describing: out.providerOutcomes["codex"])))")
        XCTAssertNotNil(out.dashboard.dataQuality.first { $0.contains("will resume next refresh") },
                        "X1:failure 由 loud note 承載")
    }

    /// X2:enabled 但 **adapter 缺席** 的 provider(設定殘留/版本偏差)有 poisoned persisted state
    /// ⇒ 仍必須進 poison 排除集——sweep 對其窗零交付、record 一 byte 不動(W1 domain closure)。
    func testV3X2AdapterlessEnabledPoisonedStillExcluded() throws {
        let dir = makeTempDir()
        // 磁碟構造 ghost provider:limits 有 record(gen=1、sweep 可交付窗)+ scan ack 超前(poison row 5)。
        var ghost = LimitEngine.PersistedProvider()
        ghost.reconcileGeneration = 1
        ghost.primary = LimitEngine.PersistedWindow(percent: 60, resetsAt: Date(timeIntervalSinceNow: -60),
                                                    observedAt: Date(timeIntervalSinceNow: -3600),
                                                    windowMinutes: 300, corrected: false, expiryHandled: false,
                                                    history: [])
        writeLimits(dir, ["ghost": ghost])
        writeScan(dir, ["ghost": ScanState(files: ["g": FileScanMark(offset: 1, size: 1)], ackGeneration: 5)])
        let limBefore = readLimits(dir)["ghost"]
        // enabledProviders 含 ghost;adapters 完全沒有 ghost 的實例。
        let other = MockAdapter("codex") { state in
            (AdapterRefreshResult(events: [], rateLimits: [], completeness: .complete), state)
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["ghost", "codex"]),
                                 adapters: [other], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        let out = runRefresh(c)
        XCTAssertEqual(out.transitions.filter(isReset).count, 0,
                       "X2:adapterless poisoned provider 不得由 sweep 交付 reset(得到 \(out.transitions))")
        XCTAssertEqual(readLimits(dir)["ghost"], limBefore,
                       "X2:poisoned ghost 的 record 一 byte 不得動(含 expiryHandled)")
    }

    /// X3(test-only counterleg;production 的 secondary scoping 已於 clearing-2 落地——
    /// 判別力由 F-X3 falsification 證明:revert secondary fold 的 scoping 必使本測紅):
    /// established B 的 **secondary(weekly)** stale 讀數混入 A 的 full 批,不得被改寫。
    func testV3X3SecondaryWindowAlsoScopedToReconcilingProvider() {
        let dir = makeTempDir()
        let e = LimitEngine(stateURL: limitsURL(dir), durabilityOps: DurabilityOpsRecorder().ops)
        let bBase = RateLimitReading(providerId: "pb", observedAt: date("2026-01-15T10:00:00Z"),
                                     primary: RateLimitWindowReading(usedPercent: 40, windowMinutes: 300,
                                                                     resetsAt: date("2026-01-15T14:00:00Z")),
                                     secondary: RateLimitWindowReading(usedPercent: 85, windowMinutes: 10080,
                                                                       resetsAt: date("2026-01-20T10:00:00Z")))
        _ = e.ingestTransitions(readings: [bBase], settings: CoreSettings(),
                                now: date("2026-01-15T10:01:00Z"), reconcilingProvider: "pb")
        XCTAssertEqual(readLimits(dir)["pb"]?.secondary?.percent, 85, "前置:B weekly 85")
        // A full 批混入 B 的 stale secondary 低讀數(observedAt 早於 committed)。
        let bStale = RateLimitReading(providerId: "pb", observedAt: date("2026-01-15T09:00:00Z"),
                                      primary: nil,
                                      secondary: RateLimitWindowReading(usedPercent: 10, windowMinutes: 10080,
                                                                        resetsAt: date("2026-01-20T10:00:00Z")))
        let t = e.ingestTransitions(readings: [rd("pa", 50, at: "2026-01-15T10:05:00Z"), bStale],
                                    settings: CoreSettings(), fullReindex: true,
                                    now: date("2026-01-15T10:06:00Z"), reconcilingProvider: "pa")
        XCTAssertEqual(t.filter { if case .crossedThreshold(let p, _, _, _) = $0 { return p == "pb" } else { return false } }.count, 0,
                       "X3:B 零 crossings")
        XCTAssertEqual(readLimits(dir)["pb"]?.secondary?.percent, 85,
                       "X3:B 的 weekly 亦受 temporal authority 保護(full 豁免只屬主體 A)")
    }

    // MARK: cumulative(gen/ack 建立;wm 軸不適用)

    func testV3CumulativeEstablishesGenAndAck() throws {
        let dir = makeTempDir()
        let adapter = MockAdapter("codex", historyModel: .cumulativeSnapshotOnly) { _ in
            (AdapterRefreshResult(events: [self.ev("v3cum", "codex")], rateLimits: [self.rd("codex", 60, at: "2026-01-15T10:00:00Z")],
                                  completeness: .complete),
             ScanState(files: ["c": FileScanMark(offset: 1, size: 1)]))
        }
        let c = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["codex"]),
                                 adapters: [adapter], limitsDurabilityOps: DurabilityOpsRecorder().ops)
        _ = runRefresh(c)
        XCTAssertEqual(readLimits(dir)["codex"]?.reconcileGeneration, 1, "cumulative 亦建立 generation")
        XCTAssertEqual(readScan(dir)["codex"]?.ackGeneration, 1, "cumulative 亦建立 ack")
    }
}
