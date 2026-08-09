import Foundation
import UsageCore

// F17 信任層 substrate 測試(契約 v5 §7 fixtures 的落地;全部 deterministic、時刻注入)。

// MARK: - 狀態機(契約 §5)

final class TrustHealthMachineTests: XCTestCase {
    typealias M = SourceHealthMachine

    func testEveryStateEntryAndExit() {
        var s = M.State()
        XCTAssertEqual(s.health, .ok)
        // 進入每個失敗態,並以 success 離開(退避成功 → ok、計數歸零)
        for (event, expected): (SourceObservationEvent, SourceHealth) in [
            (.transportFailure, .transientError),
            (.rateLimited, .rateLimited),
            (.authRejected, .authExpired),
        ] {
            s = M.step(M.State(), event)
            XCTAssertEqual(s.health, expected)
            s = M.step(s, .success)
            XCTAssertEqual(s, M.State(), "success 離開 \(expected) 並歸零計數")
        }
    }

    func testSchemaKillEscalationPathsAndAbsorbing() {
        // decoder breaking(必要欄位缺/型別錯)= **立即** kill(契約 §5;r1 修正)
        let broken = M.step(M.State(), .schemaBreaking)
        XCTAssertEqual(broken.health, .schemaKilled, "breaking mismatch 立即 kill,不累積")
        // invalid body(JSON 壞)= 3 連升級
        var s = M.State()
        s = M.step(s, .invalidBody)
        XCTAssertEqual(s.health, .transientError, "單次 invalid body 先暫態")
        s = M.step(s, .invalidBody)
        XCTAssertEqual(s.health, .transientError)
        s = M.step(s, .invalidBody)
        XCTAssertEqual(s.health, .schemaKilled, "連續 3 次 invalid body 才 kill")
        // 吸收態:一般事件不離開(含 success —— 離開只經 reactivate)
        XCTAssertEqual(M.step(s, .success).health, .schemaKilled)
        XCTAssertEqual(M.step(s, .transportFailure).health, .schemaKilled)
        // 中途成功打斷計數
        var t = M.step(M.State(), .invalidBody)
        t = M.step(t, .success)
        t = M.step(t, .invalidBody)
        t = M.step(t, .invalidBody)
        XCTAssertEqual(t.health, .transientError, "成功歸零後需重新累積 3 次")
        // 404/410 同門檻、獨立計數(transport 兜底不升級)
        var g = M.State()
        g = M.step(g, .endpointGone)
        g = M.step(g, .invalidBody)      // 異型打斷 gone 計數
        g = M.step(g, .endpointGone)
        g = M.step(g, .endpointGone)
        XCTAssertEqual(g.health, .transientError, "異型互相打斷,未達 3 連")
        var tr = M.State()
        tr = M.step(tr, .transportFailure)
        tr = M.step(tr, .transportFailure)
        tr = M.step(tr, .transportFailure)
        XCTAssertEqual(tr.health, .transientError, "transport 兜底永不升級 kill")
    }

    func testReactivateSemantics() {
        let killed = M.State(health: .schemaKilled, consecutiveInvalidBodies: 3, consecutiveGoneFailures: 0)
        XCTAssertEqual(M.reactivate(killed, probeResult: .success), M.State(), "探測成功 → 完全復活")
        XCTAssertEqual(M.reactivate(killed, probeResult: .schemaBreaking).health, .schemaKilled,
                       "再 mismatch 直接回 kill(不重新累積)")
        XCTAssertEqual(M.reactivate(killed, probeResult: .invalidBody).health, .schemaKilled,
                       "invalid body 探測同樣直接回 kill")
        XCTAssertEqual(M.reactivate(killed, probeResult: .endpointGone).health, .schemaKilled)
        XCTAssertEqual(M.reactivate(killed, probeResult: .rateLimited).health, .rateLimited,
                       "非 schema 失敗 → 進對應暫態(已離開吸收態)")
    }

    func testStaleOverlayAndRecoveryMapping() {
        // stale 只在無具體失敗態時成立(契約 §3 優先序)
        XCTAssertEqual(HealthDisplay.effective(machine: .ok, isStale: true), .stale)
        XCTAssertEqual(HealthDisplay.effective(machine: .rateLimited, isStale: true), .rateLimited,
                       "具體失敗態壓過 stale")
        XCTAssertEqual(HealthDisplay.effective(machine: .ok, isStale: false), .ok)
        // recovery 封閉映射(契約 §1/§5)
        XCTAssertEqual(HealthDisplay.recovery(for: .ok, presence: .disabled, cli: "grok"), .reEnableToggle)
        XCTAssertEqual(HealthDisplay.recovery(for: .ok, presence: .unavailable(.notLoggedIn), cli: "grok"),
                       .reLogin(cli: "grok"))
        XCTAssertEqual(HealthDisplay.recovery(for: .authExpired, presence: .active, cli: "codex"),
                       .reLogin(cli: "codex"))
        XCTAssertEqual(HealthDisplay.recovery(for: .schemaKilled, presence: .active, cli: "grok"), .updateApp)
        XCTAssertEqual(HealthDisplay.recovery(for: .transientError, presence: .active, cli: "grok"), .retryLater)
        XCTAssertEqual(HealthDisplay.recovery(for: .stale, presence: .active, cli: "grok"), .none)
    }
}

// MARK: - Freshness 兩層(契約 §3)

final class TrustFreshnessTests: XCTestCase {
    let w: TimeInterval = 600   // window 10 分鐘
    let t0 = date("2026-08-01T10:00:00Z")

    func testNilObservationNeverStale() {
        let a = Freshness.assessObservation(lastObservedOk: nil, window: w, currentlyStale: false, now: t0)
        XCTAssertFalse(a.isStale, "首次啟用(nil 觀測)不參與 stale 判定")
    }

    func testHysteresisBands() {
        // enter 於 age > 2.2×w;exit 於 age < 1.8×w(契約明文帶)
        let justUnderEnter = t0.addingTimeInterval(2.1 * w)
        let overEnter = t0.addingTimeInterval(2.3 * w)
        let betweenBands = t0.addingTimeInterval(2.0 * w)
        let underExit = t0.addingTimeInterval(1.7 * w)
        XCTAssertFalse(Freshness.assessObservation(lastObservedOk: t0, window: w, currentlyStale: false,
                                                   now: justUnderEnter).isStale)
        XCTAssertTrue(Freshness.assessObservation(lastObservedOk: t0, window: w, currentlyStale: false,
                                                  now: overEnter).isStale)
        XCTAssertTrue(Freshness.assessObservation(lastObservedOk: t0, window: w, currentlyStale: true,
                                                  now: betweenBands).isStale, "帶內維持既有態(遲滯)")
        XCTAssertFalse(Freshness.assessObservation(lastObservedOk: t0, window: w, currentlyStale: true,
                                                   now: underExit).isStale)
    }

    func testNegativeAgeIsClockChangedNotStale() {
        let future = t0.addingTimeInterval(3600)
        let a = Freshness.assessObservation(lastObservedOk: future, window: w, currentlyStale: false, now: t0)
        XCTAssertEqual(a.note, .clockChanged)
        XCTAssertFalse(a.isStale, "時鐘異常不轉 stale(顯示 clock changed)")
        let b = Freshness.assessObservation(lastObservedOk: future, window: w, currentlyStale: true, now: t0)
        XCTAssertTrue(b.isStale, "時鐘異常也不翻轉既有態")
    }
}

// MARK: - Conflict flag 生命週期(契約 §2)

final class TrustConflictTests: XCTestCase {
    let t0 = date("2026-08-01T10:00:00Z")

    private func pair(_ tracker: inout ConflictTracker, minute: Int, local: Double, api: Double) -> Bool {
        let la = t0.addingTimeInterval(Double(minute) * 60)
        let aa = la.addingTimeInterval(60)   // 相差 1 分鐘(可比)
        return tracker.observe(localPercent: local, localObservedAt: la,
                               apiPercent: api, apiObservedAt: aa)
    }

    func testRaiseAfterThreeDivergentAndPairDedup() {
        var c = ConflictTracker()
        XCTAssertTrue(pair(&c, minute: 0, local: 30, api: 55))
        XCTAssertFalse(c.isRaised)
        // 同一 pair 重複投遞不重計(identity = observedAt 組)
        XCTAssertFalse(pair(&c, minute: 0, local: 30, api: 55), "同 pair 不構成新一輪")
        XCTAssertTrue(pair(&c, minute: 20, local: 32, api: 58))
        XCTAssertFalse(c.isRaised)
        XCTAssertTrue(pair(&c, minute: 40, local: 31, api: 60))
        XCTAssertTrue(c.isRaised, "連續 3 輪可比且差 >10pt → 升起")
    }

    func testIncomparableWhenObservedTooFarApart() {
        var c = ConflictTracker()
        let la = t0
        let aa = t0.addingTimeInterval(31 * 60)   // >30min → 不可比
        XCTAssertFalse(c.observe(localPercent: 10, localObservedAt: la,
                                 apiPercent: 90, apiObservedAt: aa), "相距 >30min 絕不誤報")
    }

    func testClearByConvergenceAndByWithdrawal() {
        var c = ConflictTracker()
        _ = pair(&c, minute: 0, local: 30, api: 55)
        _ = pair(&c, minute: 20, local: 30, api: 55)
        _ = pair(&c, minute: 40, local: 30, api: 55)
        XCTAssertTrue(c.isRaised)
        _ = pair(&c, minute: 60, local: 50, api: 52)
        _ = pair(&c, minute: 80, local: 51, api: 53)
        XCTAssertTrue(c.isRaised, "收斂未滿 3 輪仍維持")
        _ = pair(&c, minute: 100, local: 52, api: 54)
        XCTAssertFalse(c.isRaised, "連續 3 輪收斂 → 清除")

        var d = ConflictTracker()
        _ = pair(&d, minute: 0, local: 30, api: 55)
        _ = pair(&d, minute: 20, local: 30, api: 55)
        _ = pair(&d, minute: 40, local: 30, api: 55)
        XCTAssertTrue(d.isRaised)
        d.sourceWithdrawn()
        XCTAssertFalse(d.isRaised, "單源撤回(presence ≠ active)→ 清除")
    }

    func testPairDedupSurvivesNonAdjacencyAndReset() {
        // r1 三鏡:P1→P2→P1 不得重計;reset(過期/撤回)後老 pair 不得復用為新證據
        var c = ConflictTracker()
        XCTAssertTrue(pair(&c, minute: 0, local: 30, api: 55))    // P1
        XCTAssertTrue(pair(&c, minute: 20, local: 30, api: 55))   // P2
        let la1 = t0, aa1 = t0.addingTimeInterval(60)
        XCTAssertFalse(c.observe(localPercent: 30, localObservedAt: la1,
                                 apiPercent: 55, apiObservedAt: aa1),
                       "P1 非相鄰重現(P1→P2→P1)不得重計 —— 高水位去重")
        XCTAssertFalse(c.isRaised, "兩組真實 pair 不足以升起")
        // 過期 reset 後,未前進的老 pair 不得復算(r1 sol#3)
        var e = ConflictTracker()
        _ = pair(&e, minute: 0, local: 30, api: 55)
        _ = pair(&e, minute: 20, local: 30, api: 55)
        _ = pair(&e, minute: 40, local: 30, api: 55)
        XCTAssertTrue(e.isRaised)
        e.expireIfDue(now: t0.addingTimeInterval(48 * 3600), ttl: 3600)
        XCTAssertFalse(e.isRaised)
        XCTAssertFalse(pair(&e, minute: 40, local: 30, api: 55),
                       "過期後重投最後一組老 pair → 不構成新一輪(高水位不因 reset 回退)")
        XCTAssertFalse(e.isRaised)
        // r2 sol#2 + r3 兩鏡:一邊前進、另一邊**回退**(撤回源的老讀數)也不得入證。
        // 時戳必須落在 30min 可比窗內,否則可比性 guard 先擋、測不到高水位邏輯
        // (r3 抓到的空洞測試):e 的 api 高水位 = t0+41m;此處 api=+40m(回退)、
        // local=+60m(前進),相差 20m 可比 —— 舊 `||` gate 會錯誤放行,新 guard 必拒。
        let newLocal = t0.addingTimeInterval(60 * 60)
        let staleApi = t0.addingTimeInterval(40 * 60)
        XCTAssertFalse(e.observe(localPercent: 30, localObservedAt: newLocal,
                                 apiPercent: 55, apiObservedAt: staleApi),
                       "新 local + 回退 api(可比窗內)→ 拒(兩邊不回退且至少一邊前進)")
        XCTAssertFalse(e.isRaised)
    }

    func testTwoStageExpiry() {
        let ttl: TimeInterval = 3600
        var c = ConflictTracker()
        _ = pair(&c, minute: 0, local: 30, api: 55)
        _ = pair(&c, minute: 20, local: 30, api: 55)
        _ = pair(&c, minute: 40, local: 30, api: 55)
        XCTAssertTrue(c.isRaised)
        // elapsed < ttl → 保留
        c.expireIfDue(now: t0.addingTimeInterval(41 * 60 + 600), ttl: ttl)
        XCTAssertTrue(c.isRaised)
        // elapsed > ttl → 清除
        c.expireIfDue(now: t0.addingTimeInterval(41 * 60).addingTimeInterval(ttl + 1), ttl: ttl)
        XCTAssertFalse(c.isRaised, "逾 TTL 無新可比對 → 自動過期")

        // 兩段式:elapsed < 0(時鐘異常)→ 直接 expired,絕不 clamp-then-compare
        var e = ConflictTracker()
        _ = pair(&e, minute: 0, local: 30, api: 55)
        _ = pair(&e, minute: 20, local: 30, api: 55)
        _ = pair(&e, minute: 40, local: 30, api: 55)
        XCTAssertTrue(e.isRaised)
        e.expireIfDue(now: t0.addingTimeInterval(-3600), ttl: ttl)
        XCTAssertFalse(e.isRaised, "負 elapsed(回撥)視為 expired —— clamp 會偽裝成剛發生")
    }
}

// MARK: - Ordering 三類(契約 §7;對既有 LimitEngine,owner K1 fixture 準則)

final class TrustOrderingTests: XCTestCase {
    let base = date("2026-08-01T10:00:00Z")

    private func reading(_ pct: Double, at: Date) -> RateLimitReading {
        RateLimitReading(providerId: "codex", observedAt: at,
                         primary: RateLimitWindowReading(usedPercent: pct, windowMinutes: 300,
                                                         resetsAt: base.addingTimeInterval(5 * 3600)),
                         secondary: nil)
    }

    /// folded 的可觀察整態(percent + resetsAt + windowMinutes),決定性斷言不只比 percent
    /// (r1:同 percent 不同 resetsAt/來源的 regression 要抓)。注:reading 目前無 source
    /// 欄位 —— provenance 的 sourceId 維度須待 F1+F2 為 RateLimitReading 增補 source tag
    /// 後方可端到端斷言(shipped schema 限制,誠實記錄,非本 substrate PR 可解)。
    private struct FoldedState: Hashable {
        var percent: Double
        var resetsAt: Date?
        var windowMinutes: Int?
    }

    private func run(batches: [[RateLimitReading]],
                     perStep: ((Int, FoldedState) -> Void)? = nil) -> FoldedState {
        let dir = makeTempDir()
        let engine = LimitEngine(stateURL: dir.appendingPathComponent("limits.json"))
        let settings = CoreSettings()
        let ledger = UsageLedger(fileURL: nil)
        let now = base.addingTimeInterval(4 * 3600)
        var last = FoldedState(percent: -1, resetsAt: nil, windowMinutes: nil)
        for (i, batch) in batches.enumerated() {
            _ = engine.ingest(readings: batch, settings: settings, now: now)
            let st = engine.limitState(providerId: "codex", ledger: ledger, settings: settings, now: now)
            last = FoldedState(percent: st.fiveHour.usedPercent ?? -1,
                               resetsAt: st.fiveHour.resetAt,
                               windowMinutes: st.fiveHour.windowMinutes)
            perStep?(i, last)
        }
        return last
    }

    func testSameOrderedSequenceIsDeterministic() {
        // 準則 1:同一 ordered event sequence 重跑,**整個可觀察折疊態**必須一致
        let seq: [[RateLimitReading]] = [
            [reading(80, at: base)],
            [reading(70, at: base.addingTimeInterval(600))],
            [reading(60, at: base.addingTimeInterval(1200))],
        ]
        var stepsA: [FoldedState] = [], stepsB: [FoldedState] = []
        let a = run(batches: seq) { _, s in stepsA.append(s) }
        let b = run(batches: seq) { _, s in stepsB.append(s) }
        XCTAssertEqual(a, b, "same ordered sequence → 同一終態(percent+resetsAt+window)")
        XCTAssertEqual(stepsA, stepsB, "每個中間態也逐一相同")
    }

    func testCrossSourcePermutationsSafetyInvariant() {
        // 準則 2(K1 反例類):fold 80;A={70@t1, 60@t2}(內部有序)、B={90@tb, tb 最早}。
        // 允許保留態不同,但**每一步**(不只終態)folded used% 都不得低於「該步已接受
        // 觀測所能證成的最低值」—— 分歧只許保守側(較高 used / 較低 remaining)。
        let t1 = base.addingTimeInterval(600)
        let t2 = base.addingTimeInterval(1200)
        let tb = base.addingTimeInterval(60)    // B 的 observedAt 最早(K1 反例的關鍵)
        let a70 = reading(70, at: t1), a60 = reading(60, at: t2), b90 = reading(90, at: tb)
        let seed = reading(80, at: base)

        // 每條 interleaving 斷言**每步的精確 folded 值**(r2 sol#8:寬鬆下界擋不住
        // 「單讀即降」的壞引擎;精確序列同時 enforce 兩連降語義與 per-sequence 決定性):
        // - AAB step1 = 80(70 只是第一低:pending 凍結,percent 不動)→ step2 = 60(兩連)
        // - ABA step2 = 90(B 升)→ step3 = 60(pending 70@t1 + 60@t2 兩連確認)
        // - BAA step1 = 90 → step3 = 60(同上)
        // 單讀即降的壞引擎會在 step1 炸(80→70);越權樂觀值同樣炸。
        let interleavings: [(name: String, order: [[RateLimitReading]], expected: [Double])] = [
            ("AAB", [[seed], [a70], [a60], [b90]], [80, 80, 60, 90]),
            ("ABA", [[seed], [a70], [b90], [a60]], [80, 80, 90, 60]),
            ("BAA", [[seed], [b90], [a70], [a60]], [80, 90, 90, 60]),
        ]
        var finals: Set<Double> = []
        for c in interleavings {
            let f = run(batches: c.order) { i, s in
                XCTAssertEqual(s.percent, c.expected[i], accuracy: 0.01,
                               "\(c.name) 第 \(i) 步 folded 應為 \(c.expected[i])(兩連降語義),實得 \(s.percent)")
            }
            finals.insert(f.percent)
        }
        // K1 safety 總結:兩個合法終態(90 保守高值 / 60 兩連降),無任何低於 60 的樂觀值
        XCTAssertEqual(finals, Set([60, 90]), "終態集合恰為 {60, 90}(分歧存在且皆在保守側)")
    }

    func testStabilizationConvergence() {
        // 準則 3(先證後諾):**先斷言兩條歷史真的分歧(90 vs 60)**,再餵相同的穩定
        // 後續序列;引擎證明重新一致 → 此 fixture 即為 convergence 的 regression 釘。
        let t1 = base.addingTimeInterval(600)
        let t2 = base.addingTimeInterval(1200)
        let tb = base.addingTimeInterval(60)
        let seed = reading(80, at: base)
        let histAAB: [[RateLimitReading]] = [[seed], [reading(70, at: t1)], [reading(60, at: t2)], [reading(90, at: tb)]]
        let histBAA: [[RateLimitReading]] = [[seed], [reading(90, at: tb)], [reading(70, at: t1)], [reading(60, at: t2)]]
        let divergedA = run(batches: histAAB).percent
        let divergedB = run(batches: histBAA).percent
        XCTAssertEqual(Set([divergedA, divergedB]), Set([90, 60]),
                       "前置:兩條歷史必須先真的分歧到 90/60(否則 fixture 沒在測收斂)")
        // 穩定後續:同源連續兩筆 65(observedAt 嚴格遞增、晚於一切歷史)
        let s1 = reading(65, at: base.addingTimeInterval(1800))
        let s2 = reading(65, at: base.addingTimeInterval(2400))
        var finals: Set<FoldedState> = []
        for h in [histAAB, histBAA] {
            finals.insert(run(batches: h + [[s1], [s2]]))
        }
        XCTAssertEqual(finals.count, 1,
                       "相同穩定後續(兩連 65)下兩條分歧歷史必須收斂到同一完整折疊態;實得 \(finals)")
        XCTAssertEqual(finals.first?.percent ?? -1, 65, accuracy: 0.01)
    }
}

// MARK: - Coordinator wiring(local 源 → DataSourceStatus)

final class TrustWiringTests: XCTestCase {
    private final class Box { var fail = false; var events: [UsageEvent] = []; var parseErrors = 0 }

    /// 可失敗的 mock(共用 MockAdapter 的 closure 不可 throw,此處自備)。
    private final class ThrowingMockAdapter: ProviderAdapter {
        struct Failure: Error {}
        let providerId = "mock"
        let box: Box
        init(box: Box) { self.box = box }
        var displayName: String { providerId }
        var roots: [URL] { [] }
        var watchFiles: [URL] { [] }
        var historyModel: ProviderHistoryModel { .rebuildableHistory }
        func detectAvailability() -> ProviderAvailability { ProviderAvailability(available: true, detail: "mock") }
        func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
            if box.fail { throw Failure() }
            return (AdapterRefreshResult(events: box.events, parseErrors: box.parseErrors,
                                         completeness: .complete), state)
        }
        func explainDataSources() -> String { "mock" }
        func explainRequiredPermissions() -> String { "mock" }
        func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
    }

    private func runRefresh(_ coord: UsageCoordinator) {
        let sem = DispatchSemaphore(value: 0)
        Task { _ = await coord.refresh(); sem.signal() }
        sem.wait()
    }

    private func statuses(_ coord: UsageCoordinator, now: Date) -> [DataSourceStatus] {
        let sem = DispatchSemaphore(value: 0)
        var out: [DataSourceStatus] = []
        Task { out = await coord.dataSourceStatuses(now: now); sem.signal() }
        sem.wait()
        return out
    }

    private func mkCoord(_ box: Box, dir: URL, enabled: Bool = true) -> UsageCoordinator {
        var settings = CoreSettings()
        settings.enabledProviders = enabled ? ["mock"] : []
        return UsageCoordinator(dataDir: dir, settings: settings, adapters: [ThrowingMockAdapter(box: box)])
    }

    func testActiveOkAfterSuccessfulRefresh() {
        let box = Box()
        box.events = [UsageEvent(id: "e1", providerId: "mock", projectId: "/p", projectName: "p",
                                 modelId: "m", timestamp: date("2026-08-01T09:00:00Z"),
                                 tokens: TokenBreakdown(input: 10), sourceKind: "mock")]
        let coord = mkCoord(box, dir: makeTempDir())
        runRefresh(coord)
        let s = statuses(coord, now: Date()).first { $0.providerId == "mock" }!
        XCTAssertEqual(s.presence, .active)
        XCTAssertEqual(s.health, .ok)
        XCTAssertNotNil(s.lastObservedOk, "成功 refresh 記錄觀測時刻")
        XCTAssertEqual(s.newestDataAt, date("2026-08-01T09:00:00Z"), "data age 用事件時戳(兩層語義)")
        XCTAssertEqual(s.kind, .localLogs)
        XCTAssertEqual(s.recoveryAction, .none)
    }

    func testDisabledBeatsEverything() {
        let box = Box()
        let coord = mkCoord(box, dir: makeTempDir(), enabled: false)
        runRefresh(coord)
        let s = statuses(coord, now: Date()).first { $0.providerId == "mock" }!
        XCTAssertEqual(s.presence, .disabled, "disabled 勝過一切(契約 §1 優先序)")
        XCTAssertEqual(s.recoveryAction, .reEnableToggle)
        // r1 三鏡:disabled(被跳過)的 provider 不得偽造 attempt —— connecting 判定要真
        XCTAssertEqual(s.attemptCount, 0, "被跳過的 provider attemptCount 必須為 0")
        XCTAssertNil(s.lastAttemptAt, "被跳過的 provider 無 lastAttemptAt")
    }

    func testFailedRefreshIsTransientErrorNotStaleNotGeneric() {
        let box = Box()
        let coord = mkCoord(box, dir: makeTempDir())
        runRefresh(coord)                       // 先成功一次
        box.fail = true
        runRefresh(coord)                       // 再失敗
        let s = statuses(coord, now: Date()).first { $0.providerId == "mock" }!
        XCTAssertEqual(s.health, .transientError, "scan 失敗 = transientError(分態,不混 generic)")
        XCTAssertEqual(s.recoveryAction, .retryLater)
        XCTAssertNotNil(s.lastObservedOk, "上次成功觀測保留(last-good 語義)")
    }

    func testStaleWhenObservationWindowExceededAndParseWarnings() {
        let box = Box()
        let coord = mkCoord(box, dir: makeTempDir())
        runRefresh(coord)
        // 超遲滯帶(window 300s × 2.2):以未來 now 查詢 → stale(觀測太舊,非使用者 idle)
        let farFuture = Date().addingTimeInterval(300 * 3 + 60)
        let s = statuses(coord, now: farFuture).first { $0.providerId == "mock" }!
        XCTAssertEqual(s.health, .stale, "超窗未觀測 → stale(具體失敗態缺席時的默認降級)")
        // parse warnings 註記(成功 scan + 壞行計數)
        box.parseErrors = 3
        runRefresh(coord)
        let s2 = statuses(coord, now: Date()).first { $0.providerId == "mock" }!
        XCTAssertEqual(s2.provenanceNote, .parseWarnings, "parser drift 顯註記,不偽裝 idle")
        XCTAssertEqual(s2.health, .ok, "零星壞行容忍,不改 health(與現行為一致)")
    }
}

// MARK: - planLabel fallback 決策樹(契約 §2;純函數)

final class TrustPlanLabelTests: XCTestCase {
    func testDecisionTreeBranches() {
        typealias P = PlanLabelResolver
        let localOK = P.Source(value: "pro", health: .ok, presence: .active, everHadValue: true)
        let localStale = P.Source(value: "pro", health: .stale, presence: .active, everHadValue: true)
        let localFailedWithHistory = P.Source(value: "pro", health: .transientError, presence: .active, everHadValue: true)
        let localLoggedOutWithHistory = P.Source(value: "pro", health: .ok, presence: .unavailable(.notLoggedIn), everHadValue: true)
        let localDisabled = P.Source(value: "pro", health: .ok, presence: .disabled, everHadValue: true)
        let localKilled = P.Source(value: "pro", health: .schemaKilled, presence: .active, everHadValue: true)
        let localEmpty = P.Source(value: nil, health: .ok, presence: .active, everHadValue: false)
        let apiOK = P.Source(value: "plus", health: .ok, presence: .active, everHadValue: true)

        XCTAssertEqual(P.resolve(local: localOK, api: apiOK), .init(value: "pro", origin: .local, staleMark: false))
        XCTAssertEqual(P.resolve(local: localStale, api: apiOK), .init(value: "pro", origin: .local, staleMark: true))
        XCTAssertEqual(P.resolve(local: localFailedWithHistory, api: apiOK),
                       .init(value: "pro", origin: .localLastGood, staleMark: true),
                       "失敗但曾有值 → last-good,不跳源")
        XCTAssertEqual(P.resolve(local: localLoggedOutWithHistory, api: apiOK),
                       .init(value: "pro", origin: .localLastGood, staleMark: true),
                       "unavailable 曾有值 → last-good(登出不跳源)")
        XCTAssertEqual(P.resolve(local: localDisabled, api: apiOK),
                       .init(value: "plus", origin: .api, staleMark: false),
                       "disabled 源之值一律不用(全域鐵則 0b)→ 落 API")
        XCTAssertEqual(P.resolve(local: localKilled, api: apiOK),
                       .init(value: "plus", origin: .api, staleMark: false),
                       "schemaKilled 直接值不可用(全域鐵則 0a)→ 落 API")
        XCTAssertEqual(P.resolve(local: localEmpty, api: apiOK),
                       .init(value: "plus", origin: .api, staleMark: false))
        XCTAssertNil(P.resolve(local: localEmpty, api: P.Source(value: nil, health: .ok, presence: .active, everHadValue: false)),
                     "皆無 → nil(顯 —)")
        // API 側分支同規則(r1 sol#10:每個決策樹分支一 fixture)
        let apiStale = P.Source(value: "plus", health: .stale, presence: .active, everHadValue: true)
        let apiFailedWithHistory = P.Source(value: "plus", health: .rateLimited, presence: .active, everHadValue: true)
        let apiDisabled = P.Source(value: "plus", health: .ok, presence: .disabled, everHadValue: true)
        let apiKilled = P.Source(value: "plus", health: .schemaKilled, presence: .active, everHadValue: true)
        XCTAssertEqual(P.resolve(local: localEmpty, api: apiStale),
                       .init(value: "plus", origin: .api, staleMark: true), "API stale 帶標")
        XCTAssertEqual(P.resolve(local: localEmpty, api: apiFailedWithHistory),
                       .init(value: "plus", origin: .apiLastGood, staleMark: true),
                       "API 失敗曾有值 → apiLastGood(origin 不得退化成 .api)")
        XCTAssertNil(P.resolve(local: localEmpty, api: apiDisabled), "API disabled 之值一律不用")
        XCTAssertNil(P.resolve(local: localEmpty, api: apiKilled), "API killed 直接值不可用")
    }
}
