import Foundation
@testable import UsageCore

// Codex Source B(app-server)官方額度 — owner 2026-10-09 narrow lane。
// 整合層(R1–R4/R9):fresh Source B 讀值經 setCodexOfficialReadings 注入 → 下次 refresh 的 codex
// 增量 ingest 分支 union 進 Source A(rollout) → 既有單一 LimitEngine 權威折疊 → effective 跟隨 B。
// 純層(R5–R8 + gate + discovery + fetch):窄解碼/分類/隱私/guardrail/binary 定位/fail-soft。

// MARK: - fakes & helpers

private func sbSettings() -> CoreSettings {
    var s = CoreSettings(); s.enabledProviders = ["codex"]; return s
}

/// Source A(rollout)codex adapter 替身:capability = provides(5h,週)、rebuildable、
/// 每次回傳設定好的 rateLimits(observedAt 固定;重掃再發同筆對引擎 inert)。
private final class FakeCodexAdapter: ProviderAdapter, @unchecked Sendable {
    let providerId = "codex"
    var reportedLimitCapability: ReportedLimitCapability { .provides(windows: [.fiveHour, .weekly]) }
    let historyModel: ProviderHistoryModel = .rebuildableHistory
    var rateLimits: [RateLimitReading]
    init(_ rateLimits: [RateLimitReading]) { self.rateLimits = rateLimits }
    var displayName: String { "Codex(fake)" }
    var roots: [URL] { [] }
    var watchFiles: [URL] { [] }
    func detectAvailability() -> ProviderAvailability { ProviderAvailability(available: true, detail: "fake") }
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        (AdapterRefreshResult(events: [], rateLimits: rateLimits, completeness: .complete), state)
    }
    func explainDataSources() -> String { "" }
    func explainRequiredPermissions() -> String { "" }
    func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
}

/// Source A codex adapter 替身,refreshUsage **throw**(模擬 rollout 讀取失敗)→ 用於驗證
/// 「B ingest 與 Source A adapter 分支解耦」:A throw 時 B 仍須浮現。
private final class ThrowingCodexAdapter: ProviderAdapter, @unchecked Sendable {
    let providerId = "codex"
    var reportedLimitCapability: ReportedLimitCapability { .provides(windows: [.fiveHour, .weekly]) }
    let historyModel: ProviderHistoryModel = .rebuildableHistory
    struct Boom: Error {}
    var displayName: String { "Codex(throwing)" }
    var roots: [URL] { [] }
    var watchFiles: [URL] { [] }
    func detectAvailability() -> ProviderAvailability { ProviderAvailability(available: true, detail: "throwing") }
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) { throw Boom() }
    func explainDataSources() -> String { "" }
    func explainRequiredPermissions() -> String { "" }
    func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
}

/// transport 替身(decode/fetch 測試用):回傳固定 result bytes 或 throw。
private struct FakeTransport: CodexAppServerLimits.Transport {
    var result: Result<Data, Error>
    func fetchRateLimitsResult(timeout: TimeInterval) throws -> Data { try result.get() }
}
private struct FakeError: Error {}

private func sbRun(_ coord: UsageCoordinator) -> RefreshOutcome {
    let sem = DispatchSemaphore(value: 0); var out: RefreshOutcome?
    Task { out = await coord.refresh(); sem.signal() }
    sem.wait(); return out!
}
private func sbRunFull(_ coord: UsageCoordinator) -> RefreshOutcome {
    let sem = DispatchSemaphore(value: 0); var out: RefreshOutcome?
    Task { out = await coord.refresh(fullReindex: true); sem.signal() }
    sem.wait(); return out!
}
private func sbSet(_ coord: UsageCoordinator, _ readings: [RateLimitReading]) {
    let sem = DispatchSemaphore(value: 0)
    Task { await coord.setCodexOfficialReadings(readings); sem.signal() }
    sem.wait()
}

private func win(_ pct: Double, _ minutes: Int, _ resetsAt: Date?) -> RateLimitWindowReading {
    RateLimitWindowReading(usedPercent: pct, windowMinutes: minutes, resetsAt: resetsAt)
}
private func codexReading(fiveHour: RateLimitWindowReading?, weekly: RateLimitWindowReading?,
                          at: Date) -> RateLimitReading {
    RateLimitReading(providerId: "codex", observedAt: at, primary: fiveHour, secondary: weekly)
}
private func codexReported(_ out: RefreshOutcome) -> ProviderReportedLimits? {
    out.dashboard.reportedLimits.first { $0.providerId == "codex" }
}
/// provided → 其百分比;其他態 → nil。
private func providedPct(_ f: ReportedLimitField?) -> Double? {
    if case .provided(let p, _, _, _) = f { return p }
    return nil
}
private func isTempUnavailable(_ f: ReportedLimitField?) -> Bool {
    if case .temporarilyUnavailable = f { return true }
    return false
}

final class CodexSourceBTests: XCTestCase {

    // MARK: - R1:真實 reset regression(rollout 19% 過期窗 + app-server 0% 新窗 → effective 0%/新窗)

    func testR1_resetRegression_freshBSupersedesExpiredA() throws {
        let now = Date()
        let aExpired = codexReading(fiveHour: win(19, 300, now.addingTimeInterval(-3600)),  // 1h 前已過期
                                    weekly: nil, at: now.addingTimeInterval(-1200))          // 觀測於 20 分前
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [FakeCodexAdapter([aExpired])])

        let before = sbRun(coord)
        XCTAssertTrue(isTempUnavailable(codexReported(before)?.fiveHour),
                      "R1 before:只有過期 Source A → 誠實降級 Temporarily unavailable(非 stale 19%、非造 0%)")

        // Source B:fresh 0%、新的 +5h 窗。
        sbSet(coord, [codexReading(fiveHour: win(0, 300, now.addingTimeInterval(5 * 3600)), weekly: nil, at: now)])
        let after = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(after)?.fiveHour) ?? -1, 0,
                       "R1 after:fresh Source B 0%/新窗須成為 effective codex 5h(現行無 B → RED)")
    }

    // MARK: - R2:同窗 fresh correction(A 10% → B 19% 同窗 → effective 19%)

    func testR2_freshSameWindowCorrection_BWins() throws {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3600)
        let a = codexReading(fiveHour: win(10, 300, reset), weekly: nil, at: now.addingTimeInterval(-600))
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [FakeCodexAdapter([a])])

        let before = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(before)?.fiveHour) ?? -1, 10, "R2 before:Source A 10%")

        sbSet(coord, [codexReading(fiveHour: win(19, 300, reset), weekly: nil, at: now)])   // 同窗、較新、較高
        let after = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(after)?.fiveHour) ?? -1, 19,
                       "R2 after:fresh Source B 同窗 19% 須勝過先落地的 10%(現行無 B → RED)")
    }

    // MARK: - R3:B 不可用 → 沿用 Source A(絕不造 0%)

    func testR3_bUnavailable_fallsBackToA_neverZero() throws {
        let now = Date()
        let a = codexReading(fiveHour: win(10, 300, now.addingTimeInterval(3 * 3600)),
                             weekly: nil, at: now.addingTimeInterval(-600))
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [FakeCodexAdapter([a])])
        sbSet(coord, [])   // B 不可用/失敗 → 清空 stash
        let out = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(out)?.fiveHour) ?? -1, 10,
                       "R3:B 不可用時 effective 跟隨 Source A 10%,絕不降成 0% 或 unavailable")
    }

    // MARK: - R4:partial B(只有 5h)— 修正 5h,既有 weekly fallback 不得被毀

    func testR4_partialB_fiveHourOnly_preservesWeeklyFallback() throws {
        let now = Date()
        // refresh1:A 只有 5h(weekly 尚未出現 → 不經持久化遮蔽後續 union 測試)。
        let fake = FakeCodexAdapter([codexReading(fiveHour: win(10, 300, now.addingTimeInterval(3 * 3600)),
                                                  weekly: nil, at: now.addingTimeInterval(-600))])
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [fake])
        _ = sbRun(coord)

        // refresh2:A 這輪才新鮮提供 weekly;B 只有 5h。union 下兩者各補一窗(replace 會丟掉 A 的 weekly)。
        fake.rateLimits = [codexReading(fiveHour: win(10, 300, now.addingTimeInterval(3 * 3600)),
                                        weekly: win(20, 10080, now.addingTimeInterval(5 * 86400)),
                                        at: now.addingTimeInterval(-60))]
        sbSet(coord, [codexReading(fiveHour: win(15, 300, now.addingTimeInterval(3 * 3600)), weekly: nil, at: now)])
        let after = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(after)?.fiveHour) ?? -1, 15, "R4:B 5h 15% 勝(現行無 B → RED)")
        XCTAssertEqual(providedPct(codexReported(after)?.weekly) ?? -1, 20,
                       "R4:B 未帶 weekly → A 的 weekly(union)須補上;若 merge 改 replace(drop A)則 weekly RED")
    }

    // MARK: - R9:B 5h 進新窗,weekly 留在既有有效窗(不得跨窗污染)

    func testR9_bFiveHourResetDoesNotDamageWeekly() throws {
        let now = Date()
        let a = codexReading(fiveHour: win(19, 300, now.addingTimeInterval(-3600)),          // 5h 已過期
                             weekly: win(50, 10080, now.addingTimeInterval(5 * 86400)),        // weekly 仍有效
                             at: now.addingTimeInterval(-1200))
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [FakeCodexAdapter([a])])
        _ = sbRun(coord)

        sbSet(coord, [codexReading(fiveHour: win(0, 300, now.addingTimeInterval(5 * 3600)), weekly: nil, at: now)])
        let after = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(after)?.fiveHour) ?? -1, 0, "R9:5h 進新窗 0%(現行無 B → RED)")
        XCTAssertEqual(providedPct(codexReported(after)?.weekly) ?? -1, 50,
                       "R9:weekly 留在既有有效窗 50%,不得因 5h 換窗被 tombstone")
    }

    // MARK: - R5:窗型分類(300→5h、10080→週;位置無關;未知窗長 fail-closed)

    func testR5_windowClassificationByDuration() throws {
        let now = Date()
        func dec(_ json: String) -> [RateLimitReading] {
            if case .ok(let r) = CodexAppServerLimits.decode(resultJSON: Data(json.utf8), observedAt: now) { return r }
            return []
        }
        // 正常:primary=300、secondary=10080
        let r1 = dec(#"{"rateLimits":{"primary":{"usedPercent":54,"windowDurationMins":300,"resetsAt":1783881382},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1784354760}}}"#)
        XCTAssertEqual(r1.first?.primary?.windowMinutes, 300)
        XCTAssertEqual(r1.first?.secondary?.windowMinutes, 10080)
        // 反序:primary=10080、secondary=300 → 仍以 windowDurationMins 正確歸位(非位置)
        let r2 = dec(#"{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1784354760},"secondary":{"usedPercent":54,"windowDurationMins":300,"resetsAt":1783881382}}}"#)
        XCTAssertEqual(r2.first?.primary?.windowMinutes, 300, "反序仍須歸到 5h 槽")
        XCTAssertEqual(r2.first?.primary?.usedPercent, 54)
        XCTAssertEqual(r2.first?.secondary?.windowMinutes, 10080)
        // present 的未知窗長(60)→ 整筆 fail-soft(不誤標、不留半筆);分類正確性由 r1/r2 的合法窗覆蓋。
        let r3 = dec(#"{"rateLimits":{"primary":{"usedPercent":33,"windowDurationMins":60,"resetsAt":1783881382},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1784354760}}}"#)
        XCTAssertTrue(r3.isEmpty, "present 但未知窗長 60 → 整筆空(fail-closed,絕不誤標到 5h/週槽)")
    }

    // MARK: - R6:usedPercent 保持 USED 語義(無 100−x 反轉)

    func testR6_usedPercentStaysUsed() throws {
        let now = Date()
        guard case .ok(let r) = CodexAppServerLimits.decode(
            resultJSON: Data(#"{"rateLimits":{"primary":{"usedPercent":73,"windowDurationMins":300,"resetsAt":1783881382}}}"#.utf8),
            observedAt: now) else { XCTAssertTrue(false, "decode 應成功"); return }
        XCTAssertEqual(r.first?.primary?.usedPercent, 73, "usedPercent 須原樣保留為 USED,不得反轉成 27")
    }

    // MARK: - R7:malformed / 無 result → .malformed;transport 失敗 → fail-soft 空

    func testR7_malformedAndFailSoft() throws {
        let now = Date()
        func outcome(_ s: String) -> CodexAppServerLimits.DecodeOutcome {
            CodexAppServerLimits.decode(resultJSON: Data(s.utf8), observedAt: now)
        }
        XCTAssertEqual(outcome("not json at all"), .malformed)
        XCTAssertEqual(outcome("[1,2,3]"), .malformed, "非物件 → malformed")
        XCTAssertEqual(outcome("{}"), .malformed, "無 rateLimits → malformed")
        XCTAssertEqual(outcome(#"{"rateLimits":{}}"#), .ok([]), "有 rateLimits 物件但無窗/無 plan → 空(fail-soft)")

        // transport throw → fetchReadings 空(絕不造 0%)
        let thrown = CodexAppServerLimits.fetchReadings(
            transport: FakeTransport(result: .failure(FakeError())), timeout: 1)
        XCTAssertTrue(thrown.isEmpty, "transport 失敗 → fail-soft 空陣列")
        // transport 回 malformed → 空
        let bad = CodexAppServerLimits.fetchReadings(
            transport: FakeTransport(result: .success(Data("garbage".utf8))), timeout: 1)
        XCTAssertTrue(bad.isEmpty, "malformed result → fail-soft 空陣列")
        // transport 回好的 result → 一筆讀值
        let good = CodexAppServerLimits.fetchReadings(
            transport: FakeTransport(result: .success(Data(#"{"rateLimits":{"primary":{"usedPercent":8,"windowDurationMins":300,"resetsAt":1783881382},"secondary":{"usedPercent":44,"windowDurationMins":10080,"resetsAt":1784354760},"planType":"plus"}}"#.utf8))),
            timeout: 1)
        XCTAssertEqual(good.count, 1)
        XCTAssertEqual(good.first?.primary?.usedPercent, 8)
        XCTAssertEqual(good.first?.planType, "plus")
    }

    // MARK: - R8:隱私 — 禁用欄位不得進入讀值/其編碼

    func testR8_privacyNarrowDecodeExcludesForbiddenFields() throws {
        let now = Date()
        let json = #"""
        {"ordinaryUsageAllowed":true,
         "rateLimitResetCredits":{"availableCount":3,"id":"cred_SECRET123","description":"banked reset credit"},
         "account":{"email":"user@example.com","accountId":"acct_UUID_SECRET","authToken":"sk-secret-token-xyz"},
         "rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1783881382},
                       "secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":1784354760},
                       "planType":"plus"}}
        """#
        guard case .ok(let readings) = CodexAppServerLimits.decode(resultJSON: Data(json.utf8), observedAt: now),
              let reading = readings.first else { XCTAssertTrue(false, "decode 應成功"); return }
        XCTAssertEqual(reading.primary?.usedPercent, 10)
        XCTAssertEqual(reading.secondary?.usedPercent, 20)
        XCTAssertEqual(reading.planType, "plus")
        // 讀值的 Codable 編碼不得含任何禁用值(窄解碼結構性保證)。
        let encoded = String(data: try JSONEncoder().encode(reading), encoding: .utf8) ?? ""
        for forbidden in ["sk-secret-token-xyz", "user@example.com", "acct_UUID_SECRET",
                          "cred_SECRET123", "banked reset credit", "ordinaryUsageAllowed", "availableCount"] {
            XCTAssertFalse(encoded.contains(forbidden), "禁用欄位 \(forbidden) 不得出現在讀值編碼")
        }
    }

    // MARK: - fetch gate(owner guardrails:single-flight + ~60s 最小間隔;手動刷新亦受同一最小間隔、無例外)

    func testFetchGate_guardrails() throws {
        let t0: TimeInterval = 1000   // 單調 uptime 秒(非 wall-clock;系統時鐘回/前跳不影響)
        var gate = CodexAppServerLimits.FetchGate(minInterval: 60)
        XCTAssertEqual(gate.decide(now: t0), .proceed, "idle → proceed")
        gate.begin()
        XCTAssertEqual(gate.decide(now: t0), .skipInFlight, "進行中 → single-flight 跳過")
        gate.finish(at: t0)
        XCTAssertEqual(gate.decide(now: t0 + 30), .skipMinInterval, "30s < 60s → 防 spawn storm(含手動,無例外)")
        XCTAssertEqual(gate.decide(now: t0 + 59.9), .skipMinInterval, "邊界內仍 skip")
        XCTAssertEqual(gate.decide(now: t0 + 61), .proceed, "≥60s → proceed")
    }

    // MARK: - binary discovery(CODEX_BIN 覆寫命中;皆無 + login-shell nil → nil)

    func testDiscovery_envOverrideAndNotFound() throws {
        let dir = makeTempDir()
        let bin = dir.appendingPathComponent("codex")
        FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        let found = CodexAppServerLimits.discoverCodexBinary(env: ["CODEX_BIN": bin.path], home: dir)
        XCTAssertEqual(found?.path, bin.path, "CODEX_BIN 指向的可執行檔須被採用")

        let emptyHome = makeTempDir()
        let none = CodexAppServerLimits.discoverCodexBinary(env: [:], home: emptyHome, globalPaths: [])
        XCTAssertNil(none, "無任何候選(hermetic:globalPaths 注入空)→ nil(呼叫端 fail-soft)")
    }

    // MARK: - R8b:planType sanitize(privacy fail-closed — 不把任意字串當 durable 方案標籤)

    func testPlanTypeSanitize_rejectsNonLabelStrings() throws {
        typealias C = CodexAppServerLimits
        for ok in ["plus", "pro", "team", "enterprise", "free", "business", "Plus"] {
            XCTAssertEqual(C.sanitizedPlanType(ok), ok, "單一字母詞方案標籤保留:\(ok)")
        }
        // xcheck r2 sol BLOCKER:token/UUID 皆由 [A-Za-z0-9-] 構成,舊 charset filter 會整串放行 → 必擋。
        XCTAssertNil(C.sanitizedPlanType("sk-secret-token-xyz"), "token(含 -)→ nil")
        XCTAssertNil(C.sanitizedPlanType("550e8400-e29b-41d4-a716-446655440000"), "UUID(含 - 與數字)→ nil")
        XCTAssertNil(C.sanitizedPlanType("user@example.com"), "email → nil")
        XCTAssertNil(C.sanitizedPlanType("/Users/x/secret"), "path → nil")
        XCTAssertNil(C.sanitizedPlanType("Max 20x"), "含空白+數字 → nil(非 codex 單詞方案形)")
        XCTAssertNil(C.sanitizedPlanType("pro_v2"), "含 _ 與數字 → nil")
        XCTAssertNil(C.sanitizedPlanType(String(repeating: "x", count: 17)), "超長(>16)→ nil")
        XCTAssertNil(C.sanitizedPlanType(""), "空 → nil")
        XCTAssertNil(C.sanitizedPlanType(nil), "nil → nil")
    }

    // MARK: - E1:usedPercent 範圍驗證(fail-closed — 不以無效值覆蓋有效 Source A)

    func testPercentValidation_presentButBadWindowFailsSoftWholeReading() throws {
        let now = Date()
        func dec(_ json: String) -> [RateLimitReading] {
            if case .ok(let r) = CodexAppServerLimits.decode(resultJSON: Data(json.utf8), observedAt: now) { return r }
            return []
        }
        // present-but-bad(percent -5 / 150 / 未知窗長 60):**整筆** fail-soft 空 —— 不發半筆(避免
        // primary 槽 nil + weekly 槽有值被引擎誤判成「5h 撤回」而 tombstone;xcheck r3 grok/luna/sol)。
        XCTAssertTrue(dec(#"{"rateLimits":{"primary":{"usedPercent":-5,"windowDurationMins":300,"resetsAt":1783881382},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1784354760}}}"#).isEmpty,
                      "present primary -5 + 合法 weekly → 整筆空(不留會誤觸 tombstone 的半筆)")
        XCTAssertTrue(dec(#"{"rateLimits":{"primary":{"usedPercent":150,"windowDurationMins":300,"resetsAt":1783881382},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1784354760}}}"#).isEmpty,
                      "present primary 150 → 整筆空")
        XCTAssertTrue(dec(#"{"rateLimits":{"primary":{"usedPercent":33,"windowDurationMins":60,"resetsAt":1783881382},"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1784354760}}}"#).isEmpty,
                      "present primary 窗長 60(未知)→ 整筆空")
        // 邊界 0 / 100 合法 → 保留(雙窗)。
        let okr = dec(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1783881382},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1784354760}}}"#)
        XCTAssertEqual(okr.first?.primary?.usedPercent, 0, "0% 合法")
        XCTAssertEqual(okr.first?.secondary?.usedPercent, 100, "100% 合法")
        // 真正缺席(回應只含 primary、無 secondary)→ 合法單窗(5h-only),不整筆作廢。
        let pOnly = dec(#"{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1783881382}}}"#)
        XCTAssertEqual(pOnly.first?.primary?.usedPercent, 12, "weekly 真正缺席 → 仍合法發 5h-only")
        XCTAssertNil(pOnly.first?.secondary, "缺席 weekly = nil(合法 per-window,非壞資料)")
    }

    // MARK: - D1:codex-only 注入邊界(冒充 claude/grok 的讀值不得經此通道污染 out-of-scope provider)

    func testCodexOnlyInjectionFilter_ignoresNonCodexReadings() throws {
        let now = Date()
        let dir = makeTempDir()
        var s = CoreSettings(); s.enabledProviders = ["codex", "claude-code"]
        // claude adapter 存在但無資料(空 roots / 無 statusline)→ claude limit 為 absent。
        let claude = ClaudeCodeAdapter(roots: [makeTempDir()], statuslineFiles: [], planConfigFiles: [])
        let codexA = FakeCodexAdapter([codexReading(fiveHour: win(10, 300, now.addingTimeInterval(3 * 3600)),
                                                    weekly: nil, at: now.addingTimeInterval(-600))])
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [codexA, claude])
        _ = sbRun(coord)

        // 注入:一筆冒充 claude-code 的 99%(惡意/誤用)+ 一筆真 codex 15%。filter 應只留 codex。
        sbSet(coord, [
            RateLimitReading(providerId: "claude-code", observedAt: now,
                             primary: win(99, 300, now.addingTimeInterval(3 * 3600)), secondary: nil),
            codexReading(fiveHour: win(15, 300, now.addingTimeInterval(3 * 3600)), weekly: nil, at: now),
        ])
        let out = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(out)?.fiveHour) ?? -1, 15, "真 codex 讀值生效")
        let claudeField = out.dashboard.reportedLimits.first { $0.providerId == "claude-code" }?.fiveHour
        XCTAssertNil(providedPct(claudeField),
                     "冒充 claude 的 99% 須被 codex-only filter 擋掉 → claude 5h 不得變成 provided(99)")
    }

    // MARK: - resetsAt 合理性界(防荒謬 epoch → 下游 Int(interval) trap 崩潰)

    func testResetsAtBound_rejectsImplausibleEpochs() throws {
        let observedAt = Date()
        func primary(_ resetsAtJSON: String) -> RateLimitWindowReading? {
            let json = #"{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300,"resetsAt":\#(resetsAtJSON)}}}"#
            if case .ok(let r) = CodexAppServerLimits.decode(resultJSON: Data(json.utf8), observedAt: observedAt) {
                return r.first?.primary
            }
            return nil
        }
        let huge = primary("1e20")
        XCTAssertNotNil(huge, "窗本身仍可用(只是重置時刻被界掉)")
        XCTAssertNil(huge?.resetsAt, "荒謬 epoch(1e20)→ resetsAt nil(防下游 ResetLabel Int(interval) trap)")
        let okEpoch = observedAt.addingTimeInterval(5 * 3600).timeIntervalSince1970
        XCTAssertNotNil(primary(String(format: "%.0f", okEpoch))?.resetsAt, "合理 +5h 重置時刻保留")
    }

    // MARK: - B ingest 與 Source A 解耦(A adapter throw 時 B 仍浮現 = B primary)

    func testDecoupledBIngest_surfacesEvenWhenSourceAFails() throws {
        let now = Date()
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [ThrowingCodexAdapter()])
        sbSet(coord, [codexReading(fiveHour: win(12, 300, now.addingTimeInterval(3 * 3600)), weekly: nil, at: now)])
        let out = sbRun(coord)
        XCTAssertEqual(providedPct(codexReported(out)?.fiveHour) ?? -1, 12,
                       "Source A(rollout)adapter throw → 其 ingest 分支被跳過;獨立 B ingest 仍須讓 codex 顯示 B 12%")
    }

    // MARK: - JSON-RPC 行判斷(transport reader 的純邏輯;補上此前只在 reader 內、unit 無覆蓋的 envelope gap)

    func testClassifyLine_envelopeHandling() throws {
        typealias C = CodexAppServerLimits
        func obj(_ json: String) -> [String: Any] {
            ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
        }
        XCTAssertEqual(C.classifyLine(obj(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)), .ignore, "id≠2(init 回應)→ ignore")
        XCTAssertEqual(C.classifyLine(obj(#"{"id":2,"error":{"code":-32000}}"#)), .rpcError, "id==2+error 無 result → rpcError")
        XCTAssertEqual(C.classifyLine(obj(#"{"id":2,"error":{"code":-32000},"result":{"rateLimits":{}}}"#)), .rpcError,
                       "id==2 同時帶非-null error 與 result(畸形 envelope)→ rpcError(xcheck r3 luna/sol)")
        XCTAssertEqual(C.classifyLine(obj(#"{"id":2}"#)), .rpcError, "id==2 無 result → rpcError")
        // 正常:id==2 + result(+ error:null)→ .result(不加 jsonrpc 版本 gate;真實 codex 不滿足嚴格 2.0)。
        if case .result = C.classifyLine(obj(#"{"id":2,"result":{"rateLimits":{}}}"#)) {} else {
            XCTAssertTrue(false, "id==2+result → .result")
        }
        if case .result = C.classifyLine(obj(#"{"id":2,"error":null,"result":{"rateLimits":{}}}"#)) {} else {
            XCTAssertTrue(false, "error:null + result → .result(null error 視同無 error)")
        }
    }

    // MARK: - full reindex 時 STALE B 不得蓋過較新的 A(獨立 B ingest 固定 ordinary;xcheck r5 grok MAJOR)

    func testFullReindexStaleBDoesNotClobberFreshA() throws {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3600)
        let fake = FakeCodexAdapter([codexReading(fiveHour: win(40, 300, reset), weekly: nil, at: now)])  // A 40% @ now(新)
        let dir = makeTempDir()
        let coord = UsageCoordinator(dataDir: dir, settings: sbSettings(), adapters: [fake])
        sbSet(coord, [codexReading(fiveHour: win(19, 300, reset), weekly: nil,
                                   at: now.addingTimeInterval(-3600))])   // stash:STALE B 19% @ 1h 前
        // normal:A 新於 B → A 40% 勝(stale B 以 observedAt 自然落敗)。
        XCTAssertEqual(providedPct(codexReported(sbRun(coord))?.fiveHour) ?? -1, 40, "normal:較新 A 40% 勝過 stale B")
        // full reindex:獨立 B ingest 固定 ordinary(非 fullReindex)→ stale B 因 observedAt<=committed 而 inert,
        // **不得**以重建豁免無條件蓋過重建後較新的 A。若誤傳 fullReindex 旗標則 stale B 會變 19%(RED)。
        XCTAssertEqual(providedPct(codexReported(sbRunFull(coord))?.fiveHour) ?? -1, 40,
                       "full reindex 後仍 A 40%:stale B 不得 clobber 較新的 A(xcheck r5 grok MAJOR 修復)")
    }
}
