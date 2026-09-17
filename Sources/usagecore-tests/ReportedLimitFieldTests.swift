import Foundation
@testable import UsageCore

// MARK: - M1(usage ≠ limits split)red-first:provider-reported limit 四態、投影、載體
//
// 名稱由 design v0.7 §2.4 固定(實作時不得改名)。期望值全部手寫(不用實作當 oracle);
// 投影測試一律以絕對 epoch fixture `T` 注入 `now:`(D51),不讀系統時鐘。

/// 絕對 epoch fixture(D51):與牆鐘相距遠超倒數粒度 —— 省略 `now:` 而取 `Date()` 預設的投影,
/// 對此 fixture 只會輸出 `resets in now`(s ≤ 0),釘字面的案即 RED。
private let T = date("2026-01-15T12:00:00Z")
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400
private func plus(_ seconds: TimeInterval) -> Date { T.addingTimeInterval(seconds) }

private let bothWindows: ReportedLimitCapability = .provides(windows: [.fiveHour, .weekly])

private func win(_ percent: Double? = nil, reset: Date? = nil, _ confidence: Confidence = .high,
                 corrected: Bool = false, usedTokens: Int? = nil, budgetTokens: Int? = nil,
                 idle: Bool = false, windowMinutes: Int = 300) -> LimitWindowState {
    LimitWindowState(usedPercent: percent, usedTokens: usedTokens, budgetTokens: budgetTokens, resetAt: reset,
                     windowMinutes: windowMinutes, confidence: confidence, idle: idle, corrected: corrected)
}

/// 引擎合成的 post-reset 0%(`LimitEngine.readingBackedState` 過期分支的形狀:0%、resetAt nil、.estimated)。
private let synthesizedZero = win(0, reset: nil, .estimated)
/// claude budget 估算 37%(370/1000,5h block 於 T+2h10m 結束)。
private let budgetEstimate = win(37, reset: plus(2 * hour + 10 * 60), .estimated, usedTokens: 370, budgetTokens: 1000)
/// 從未有 reading 的窗(readingBackedState → .unknown)。
private let unknownWindow = win(nil, reset: nil, .unknown)

private func derive(_ capability: ReportedLimitCapability?, _ kind: LimitWindowKind, _ window: LimitWindowState,
                    _ official: OfficialWindowStatus, hook: Bool?, health: SourceHealth?) -> ReportedLimitField {
    ReportedLimitField.derive(capability: capability, kind: kind, window: window, official: official,
                              statuslinePresent: hook, sourceHealth: health)
}

private func isProvided(_ field: ReportedLimitField) -> Bool {
    if case .provided = field { return true }
    return false
}

private func percentPayload(_ field: ReportedLimitField) -> Double? {
    if case .provided(let percent, _, _, _) = field { return percent }
    return nil
}

// MARK: I8 輸入積(30,240 點)與七條獨立 predicate(只讀原始輸入、不呼叫 derive)

private struct InputPoint {
    let capability: ReportedLimitCapability?
    let kind: LimitWindowKind
    let official: OfficialWindowStatus
    let window: LimitWindowState
    let hook: Bool?
    let health: SourceHealth?

    var label: String {
        "cap=\(String(describing: capability)) kind=\(kind) official=\(official) conf=\(window.confidence) " +
        "pct=\(String(describing: window.usedPercent)) reset=\(window.resetAt == nil ? "nil" : "T") " +
        "corrected=\(window.corrected) hook=\(String(describing: hook)) health=\(String(describing: health))"
    }

    // R1..R7(§2.2 表;R7 = otherwise)
    var r1: Bool { capability == nil }
    var r2: Bool {
        switch capability {
        case .none: return false
        case .some(.notProvided): return true
        case .some(.provides(let windows)): return !windows.contains(kind)
        }
    }
    var r3: Bool {
        official == .usable && (window.confidence == .high || window.confidence == .stale) && window.usedPercent != nil
    }
    var r4: Bool { hook == false }
    var r5: Bool { health != nil && health != .ok }
    var r6: Bool { official == .expiredUnusable || (official == .usable && window.confidence == .estimated) }

    /// oracle = firstMatch(R1..R7);R3 的 payload 由同一個 window 建構。
    var oracle: ReportedLimitField {
        if r1 { return .unknownCapability }
        if r2 { return .notProvidedBySource }
        if r3 {
            return .provided(percent: window.usedPercent!, resetsAt: window.resetAt,
                             confidence: window.confidence, corrected: window.corrected)
        }
        if r4 { return .temporarilyUnavailable(.hookNotInstalled) }
        if r5 { return .temporarilyUnavailable(.sourceUnhealthy) }
        if r6 { return .temporarilyUnavailable(.awaitingFreshReading) }
        return .temporarilyUnavailable(.noReadingYet)
    }

    var derived: ReportedLimitField {
        derive(capability, kind, window, official, hook: hook, health: health)
    }
}

private func forEachInputPoint(_ body: (InputPoint) -> Void) {
    let capabilities: [ReportedLimitCapability?] = [nil, .notProvided, .provides(windows: [.fiveHour]),
                                                    .provides(windows: [.weekly]), bothWindows]
    let kinds: [LimitWindowKind] = [.fiveHour, .weekly]
    let officials: [OfficialWindowStatus] = [.usable, .expiredUnusable, .absent]
    let confidences: [Confidence] = [.high, .estimated, .stale, .unknown]
    let percents: [Double?] = [nil, 0, 42]
    let resets: [Date?] = [nil, T]
    let correcteds = [false, true]
    let hooks: [Bool?] = [nil, true, false]
    // SourceHealth 無 CaseIterable:手列 ok + 五個非 ok(Models.swift)
    let healths: [SourceHealth?] = [nil, .ok, .stale, .transientError, .rateLimited, .authExpired, .schemaKilled]
    for capability in capabilities {
        for kind in kinds {
            for official in officials {
                for confidence in confidences {
                    for percent in percents {
                        for reset in resets {
                            for corrected in correcteds {
                                for hook in hooks {
                                    for health in healths {
                                        body(InputPoint(capability: capability, kind: kind, official: official,
                                                        window: win(percent, reset: reset, confidence, corrected: corrected),
                                                        hook: hook, health: health))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - ReportedLimitFieldTests

final class ReportedLimitFieldTests: XCTestCase {

    // §2.2 碰撞真值表 15 案逐一(輸入 → 期望手寫;列 1/11/15 同時斷言 cue 與完整四值 payload)。
    func testPrecedence_CollisionCases() {
        let t3d = plus(3 * day)

        // 1 claude:hook 缺 + usable weekly .stale 42%(reset T+3d,corrected false)→ 3 在 4 之前;hook 缺以 cue 提示
        XCTAssertEqual(derive(bothWindows, .weekly, win(42, reset: t3d, .stale), .usable, hook: false, health: .ok),
                       .provided(percent: 42, resetsAt: t3d, confidence: .stale, corrected: false), "列 1")
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: false, sourceHealth: .ok), .hookNotDetected, "列 1 cue")
        let row1 = ReportedLimitText.render(field: .provided(percent: 42, resetsAt: t3d, confidence: .stale, corrected: false),
                                            cue: .hookNotDetected, now: T)
        XCTAssertEqual(row1.main, "42.0%", "列 1 主文")
        XCTAssertEqual(row1.secondary, "resets in 3d 0h · reading is stale · hook not detected", "列 1 次行(有序片段)")

        // 2 claude:hook 缺 + F17 stale + expiredUnusable(退回估算)→ 4 在 5、6 之前
        XCTAssertEqual(derive(bothWindows, .fiveHour, budgetEstimate, .expiredUnusable, hook: false, health: .stale),
                       .temporarilyUnavailable(.hookNotInstalled), "列 2")

        // 3 claude:hook 在 + F17 transientError + usable 合成 0% → 5 在 6 之前
        XCTAssertEqual(derive(bothWindows, .fiveHour, synthesizedZero, .usable, hook: true, health: .transientError),
                       .temporarilyUnavailable(.sourceUnhealthy), "列 3")

        // 4 codex:F17 ok + usable 合成 0%(.estimated)→ 6;不是 provided 0%(amendment A)
        XCTAssertEqual(derive(bothWindows, .fiveHour, synthesizedZero, .usable, hook: nil, health: .ok),
                       .temporarilyUnavailable(.awaitingFreshReading), "列 4")

        // 5 claude:hook 在 + F17 ok + expiredUnusable(window 帶估算 37%)→ 6;估算 % 不得進 provided(I7)
        XCTAssertEqual(derive(bothWindows, .fiveHour, budgetEstimate, .expiredUnusable, hook: true, health: .ok),
                       .temporarilyUnavailable(.awaitingFreshReading), "列 5")

        // 6 claude:hook 在 + F17 ok + absent + budget 估算 idle → 7;idle 只在 estimate 列顯示
        XCTAssertEqual(derive(bothWindows, .fiveHour, win(nil, reset: nil, .estimated, idle: true), .absent, hook: true, health: .ok),
                       .temporarilyUnavailable(.noReadingYet), "列 6")

        // 7 codex:F17 nil + absent(.unknown)→ 7;sourceHealth == nil 不觸發 5
        XCTAssertEqual(derive(bothWindows, .fiveHour, unknownWindow, .absent, hook: nil, health: nil),
                       .temporarilyUnavailable(.noReadingYet), "列 7")

        // 8 grok-code:capability .notProvided + 殘留 usable .high 42% → 2 在 3 之前(I6)
        XCTAssertEqual(derive(.notProvided, .fiveHour, win(42, reset: plus(hour), .high), .usable, hook: nil, health: .ok),
                       .notProvidedBySource, "列 8")

        // 9 claude:capability .provides([.fiveHour])、kind weekly、usable weekly reading → 2(kind ∉ windows)
        XCTAssertEqual(derive(.provides(windows: [.fiveHour]), .weekly, win(24, reset: t3d, .high), .usable, hook: true, health: .ok),
                       .notProvidedBySource, "列 9")

        // 10 任意 provider:capability nil + 任何值 → 1
        XCTAssertEqual(derive(nil, .fiveHour, win(42, reset: plus(hour), .high), .usable, hook: true, health: .ok),
                       .unknownCapability, "列 10")

        // 11 claude:hook 在 + F17 transientError + usable weekly .high 12%(reset T+3d,corrected true)→ 3 在 5 之前
        XCTAssertEqual(derive(bothWindows, .weekly, win(12, reset: t3d, .high, corrected: true), .usable, hook: true, health: .transientError),
                       .provided(percent: 12, resetsAt: t3d, confidence: .high, corrected: true), "列 11")
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: true, sourceHealth: .transientError), .sourceUnhealthy, "列 11 cue")

        // 12 grok-code:.notProvided + F17 stale + 無 reading → 2 在 5 之前
        XCTAssertEqual(derive(.notProvided, .weekly, unknownWindow, .absent, hook: nil, health: .stale),
                       .notProvidedBySource, "列 12")

        // 13 claude:hook 缺 + F17 ok + usable 合成 0%(hold 中)→ 4 在 6 之前
        XCTAssertEqual(derive(bothWindows, .fiveHour, synthesizedZero, .usable, hook: false, health: .ok),
                       .temporarilyUnavailable(.hookNotInstalled), "列 13")

        // 14 claude:hook 在 + F17 transientError + absent(.unknown)→ 5 在 7 之前
        XCTAssertEqual(derive(bothWindows, .weekly, unknownWindow, .absent, hook: true, health: .transientError),
                       .temporarilyUnavailable(.sourceUnhealthy), "列 14")

        // 15 claude:hook 缺 + F17 ok + usable weekly .high 7%(resetsAt nil)→ 3 在 4 之前;cue 提示 hook
        XCTAssertEqual(derive(bothWindows, .weekly, win(7, reset: nil, .high), .usable, hook: false, health: .ok),
                       .provided(percent: 7, resetsAt: nil, confidence: .high, corrected: false), "列 15")
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: false, sourceHealth: .ok), .hookNotDetected, "列 15 cue")
        let row15 = ReportedLimitText.render(field: .provided(percent: 7, resetsAt: nil, confidence: .high, corrected: false),
                                             cue: .hookNotDetected, now: T)
        XCTAssertEqual(row15.secondary, "hook not detected", "列 15 次行(無 reset、無 stale)")
    }

    // I8:對整個輸入積每一點斷言 derive == firstMatch(R1..R7) 且 provided ⇔ ¬R1 ∧ ¬R2 ∧ R3。
    func testPrecedence_ExhaustiveInputProductIsTotalAndSingleRule() {
        var points = 0
        forEachInputPoint { p in
            points += 1
            let out = p.derived
            XCTAssertEqual(out, p.oracle, "derive ≠ oracle @ \(p.label)")
            XCTAssertEqual(isProvided(out), !p.r1 && !p.r2 && p.r3, "provided ⇔ ¬R1 ∧ ¬R2 ∧ R3 @ \(p.label)")
        }
        XCTAssertEqual(points, 30_240, "輸入積大小(I8)")
    }

    // D21/D40:derive 只讀 usedPercent / resetAt / confidence / corrected;其餘 LimitWindowState 欄位任意變動輸出不變。
    func testPrecedence_DeriveIgnoresNonEnumeratedWindowFields() {
        var index = 0
        var sampled = 0
        forEachInputPoint { p in
            index += 1
            guard index % 41 == 0 else { return }
            sampled += 1
            let base = p.derived
            var variants: [LimitWindowState] = []
            var w = p.window
            w.usedTokens = 12_345; variants.append(w)
            w.budgetTokens = 0; variants.append(w)
            w.idle = true; variants.append(w)
            w.windowMinutes = 10_080; variants.append(w)
            w.correctedAt = T; variants.append(w)
            w.correctedReason = .reindex; variants.append(w)
            for v in variants {
                XCTAssertEqual(derive(p.capability, p.kind, v, p.official, hook: p.hook, health: p.health), base,
                               "非枚舉欄位變動改變了 derive @ \(p.label)")
            }
        }
        XCTAssertGreaterThan(sampled, 500, "抽樣點數")
    }

    // amendment A:engine 合成的 post-reset 0% 永不成為 provided(codex 與 claude 各一)。
    func testProvenance_SynthesizedPostResetZeroIsNeverProvided() {
        let codex = derive(bothWindows, .fiveHour, synthesizedZero, .usable, hook: nil, health: .ok)
        XCTAssertEqual(codex, .temporarilyUnavailable(.awaitingFreshReading), "codex 合成 0%")
        let claude = derive(bothWindows, .fiveHour, synthesizedZero, .usable, hook: true, health: .ok)
        XCTAssertEqual(claude, .temporarilyUnavailable(.awaitingFreshReading), "claude 合成 0%(hold 中)")
        for field in [codex, claude] {
            XCTAssertFalse(isProvided(field))
            let text = ReportedLimitText.render(field: field, cue: .none, now: T)
            XCTAssertNil(text.gaugePercent)
            XCTAssertEqual(text.main, "Temporarily unavailable")
            XCTAssertEqual(text.secondary, "Awaiting fresh provider reading")
        }
    }

    // I7:claude budget 估算(official ∈ {expiredUnusable, absent})永不成為 provided。
    func testProvenance_ClaudeBudgetEstimateIsNeverProvided() {
        XCTAssertEqual(derive(bothWindows, .fiveHour, budgetEstimate, .expiredUnusable, hook: true, health: .ok),
                       .temporarilyUnavailable(.awaitingFreshReading))
        XCTAssertEqual(derive(bothWindows, .fiveHour, budgetEstimate, .absent, hook: true, health: .ok),
                       .temporarilyUnavailable(.noReadingYet))
        // weekly 估算(rolling 7-day、無 reset)同樣不進 provided
        let weeklyEstimate = win(80, reset: nil, .estimated, usedTokens: 800, budgetTokens: 1000, windowMinutes: 10_080)
        for official in [OfficialWindowStatus.expiredUnusable, .absent] {
            for hook in [Bool?.none, true, false] {
                for health in [SourceHealth?.none, .ok, .stale, .transientError] {
                    let out = derive(bothWindows, .weekly, weeklyEstimate, official, hook: hook, health: health)
                    XCTAssertFalse(isProvided(out), "估算 % 進了 provided:official=\(official) hook=\(String(describing: hook)) health=\(String(describing: health))")
                    XCTAssertNil(percentPayload(out))
                }
            }
        }
    }

    // R-A2:>6h 舊但 reset 未到的真 reading 是 provided(.stale),不是 unavailable。
    func testProvenance_StaleReadingStaysProvidedWithStaleConfidence() {
        let t3d = plus(3 * day)
        let out = derive(bothWindows, .weekly, win(42, reset: t3d, .stale), .usable, hook: true, health: .ok)
        XCTAssertEqual(out, .provided(percent: 42, resetsAt: t3d, confidence: .stale, corrected: false))
        let text = ReportedLimitText.render(field: out, cue: .none, now: T)
        XCTAssertEqual(text.main, "42.0%")
        XCTAssertEqual(text.secondary, "resets in 3d 0h · reading is stale")
        XCTAssertEqual(text.gaugePercent, 42)
        // codex resetsAt nil 的 reading 亦同(引擎永不判它過期)
        XCTAssertEqual(derive(bothWindows, .fiveHour, win(55, reset: nil, .stale), .usable, hook: nil, health: .ok),
                       .provided(percent: 55, resetsAt: nil, confidence: .stale, corrected: false))
    }

    // I6:notProvidedBySource 的唯一來源是 capability 宣告。
    func testCapability_NotProvidedBeatsResidualValue() {
        let residual = win(42, reset: plus(hour), .high)
        for hook in [Bool?.none, true, false] {
            for health in [SourceHealth?.none, .ok, .stale, .transientError] {
                for official in [OfficialWindowStatus.usable, .expiredUnusable, .absent] {
                    XCTAssertEqual(derive(.notProvided, .fiveHour, residual, official, hook: hook, health: health),
                                   .notProvidedBySource, "殘留值繞過契約")
                }
            }
        }
        // 反向:capability 提供該 kind 時,reading 缺欄位 / hook 缺 / F17 非 ok 皆不得推成 notProvidedBySource
        let missingField = win(nil, reset: nil, .unknown)
        let cases: [(LimitWindowState, OfficialWindowStatus, Bool?, SourceHealth?)] = [
            (missingField, .absent, true, .ok),
            (missingField, .absent, nil, nil),
            (win(42, reset: nil, .high), .usable, false, .ok),
            (missingField, .absent, false, .ok),
            (synthesizedZero, .usable, true, .transientError),
            (missingField, .absent, nil, .stale),
        ]
        for (window, official, hook, health) in cases {
            for kind in [LimitWindowKind.fiveHour, .weekly] {
                let out = derive(bothWindows, kind, window, official, hook: hook, health: health)
                XCTAssertFalse(out == .notProvidedBySource, "capability 提供該 kind 卻推成 notProvidedBySource:\(out)")
                XCTAssertFalse(out == .unknownCapability)
            }
        }
    }

    func testCapability_KindOutsideDeclaredWindowsIsNotProvided() {
        let reading = win(24, reset: plus(3 * day), .high)
        XCTAssertEqual(derive(.provides(windows: [.fiveHour]), .weekly, reading, .usable, hook: true, health: .ok),
                       .notProvidedBySource)
        XCTAssertEqual(derive(.provides(windows: [.fiveHour]), .fiveHour, reading, .usable, hook: true, health: .ok),
                       .provided(percent: 24, resetsAt: plus(3 * day), confidence: .high, corrected: false))
        XCTAssertEqual(derive(.provides(windows: [.weekly]), .fiveHour, reading, .usable, hook: nil, health: .ok),
                       .notProvidedBySource)
        XCTAssertEqual(derive(.provides(windows: [.weekly]), .weekly, reading, .usable, hook: nil, health: .ok),
                       .provided(percent: 24, resetsAt: plus(3 * day), confidence: .high, corrected: false))
    }

    func testCapability_NilIsUnknownCapability() {
        for official in [OfficialWindowStatus.usable, .expiredUnusable, .absent] {
            for window in [win(42, reset: plus(hour), .high), synthesizedZero, unknownWindow] {
                XCTAssertEqual(derive(nil, .fiveHour, window, official, hook: false, health: .transientError), .unknownCapability)
            }
        }
        let text = ReportedLimitText.render(field: .unknownCapability, cue: .hookNotDetected, now: T)
        XCTAssertEqual(text.main, "—")
        XCTAssertEqual(text.secondary, "")
        XCTAssertNil(text.gaugePercent)
    }

    // D5/D20:走訪 production wiring 列表;每個宣告 ∈ {.notProvided, 非空 provides};集合 == 四個 provider。
    func testCapability_ProvidesWindowsAreNonEmpty() {
        let adapters = UsageCoordinator.defaultProductionAdapters
        XCTAssertEqual(adapters.count, 4)
        XCTAssertEqual(Set(adapters.map { $0.providerId }), Set(["claude-code", "codex", "grok-code", "opencode"]))
        let declared: [String: ReportedLimitCapability] = [
            "claude-code": bothWindows,      // statusline five_hour / seven_day
            "codex": bothWindows,            // rollout token_count.rate_limits
            "grok-code": .notProvided,       // plan-only + M0-2 結果(官方 status-line 無 rate-limit summary)
            "opencode": .notProvided,        // adapter 契約 disclosure(rateLimits: [])
        ]
        for adapter in adapters {
            switch adapter.reportedLimitCapability {
            case .notProvided:
                break
            case .provides(let windows):
                XCTAssertFalse(windows.isEmpty, "\(adapter.providerId):provides([]) 不是 .notProvided 的第二種拼法(D5)")
            }
            XCTAssertEqual(adapter.reportedLimitCapability, declared[adapter.providerId]!, "\(adapter.providerId) 宣告(§2.2 表)")
        }
    }

    // D7:cue 鏡射 4 < 5 的順序;只裝飾 provided 列,非 provided 的次行不含 cue 字。
    func testCue_MirrorsRuleOrderAndOnlyDecoratesProvided() {
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: false, sourceHealth: .transientError), .hookNotDetected, "hook 先於 health")
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: false, sourceHealth: nil), .hookNotDetected)
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: true, sourceHealth: .transientError), .sourceUnhealthy)
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: nil, sourceHealth: .stale), .sourceUnhealthy)
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: true, sourceHealth: .ok), .none)
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: nil, sourceHealth: nil), .none)
        XCTAssertEqual(ReportedLimitField.cue(statuslinePresent: nil, sourceHealth: .ok), .none)

        let nonProvided: [ReportedLimitField] = [
            .notProvidedBySource, .unknownCapability,
            .temporarilyUnavailable(.hookNotInstalled), .temporarilyUnavailable(.sourceUnhealthy),
            .temporarilyUnavailable(.awaitingFreshReading), .temporarilyUnavailable(.noReadingYet),
        ]
        for field in nonProvided {
            let plain = ReportedLimitText.render(field: field, cue: .none, now: T)
            for cue in [ReportedLimitCue.hookNotDetected, .sourceUnhealthy] {
                let decorated = ReportedLimitText.render(field: field, cue: cue, now: T)
                XCTAssertEqual(decorated.main, plain.main, "cue 改變了非 provided 主文:\(field)")
                XCTAssertEqual(decorated.secondary, plain.secondary, "cue 進了非 provided 次行:\(field)")
                XCTAssertFalse(decorated.secondary.contains("hook not detected"))
                XCTAssertFalse(decorated.secondary.contains("source unhealthy"))
            }
        }
        // provided 列:cue 是次行最後一個片段
        let provided = ReportedLimitField.provided(percent: 42, resetsAt: plus(2 * hour + 10 * 60), confidence: .high, corrected: false)
        XCTAssertEqual(ReportedLimitText.render(field: provided, cue: .hookNotDetected, now: T).secondary,
                       "resets in 2h 10m · hook not detected")
        XCTAssertEqual(ReportedLimitText.render(field: provided, cue: .sourceUnhealthy, now: T).secondary,
                       "resets in 2h 10m · source unhealthy")
        XCTAssertEqual(ReportedLimitText.render(field: provided, cue: .none, now: T).secondary, "resets in 2h 10m")
    }

    // I1/I2 資料面:輸入積上每個非 provided 輸出都不帶 %;provided 的 % 等於 window.usedPercent。
    func testInvariant_NoStateOtherThanProvidedCarriesPercent() {
        var nonProvided = 0
        var provided = 0
        forEachInputPoint { p in
            let out = p.derived
            if let percent = percentPayload(out) {
                provided += 1
                XCTAssertEqual(percent, p.window.usedPercent, "provided 的 % 必須取自同一個 window @ \(p.label)")
                XCTAssertTrue(isProvided(out))
            } else {
                nonProvided += 1
                XCTAssertFalse(isProvided(out))
                XCTAssertNil(ReportedLimitText.render(field: out, cue: .none, now: T).gaugePercent,
                             "非 provided 態帶了 gauge @ \(p.label)")
            }
        }
        XCTAssertGreaterThan(provided, 0)
        XCTAssertGreaterThan(nonProvided, 0)
        XCTAssertEqual(provided + nonProvided, 30_240)
    }

    // D12/D27/D43:六個非 provided 態 gauge nil、主文/次行無 %;八態皆無 affordance 字串;封閉表逐字。
    func testVocabulary_NonProvidedStatesCarryNoGaugeOrPercent() {
        let table: [(ReportedLimitField, String, String)] = [
            (.notProvidedBySource, "Not provided by this source", ""),
            (.temporarilyUnavailable(.hookNotInstalled), "Temporarily unavailable", "Statusline hook not installed"),
            (.temporarilyUnavailable(.sourceUnhealthy), "Temporarily unavailable", "Source unhealthy — see Settings → Data Health"),
            (.temporarilyUnavailable(.awaitingFreshReading), "Temporarily unavailable", "Awaiting fresh provider reading"),
            (.temporarilyUnavailable(.noReadingYet), "Temporarily unavailable", "No reading yet"),
            (.unknownCapability, "—", ""),
        ]
        for (field, main, secondary) in table {
            let text = ReportedLimitText.render(field: field, cue: .none, now: T)
            XCTAssertEqual(text.main, main, "\(field) 主文")
            XCTAssertEqual(text.secondary, secondary, "\(field) 次行")
            XCTAssertNil(text.gaugePercent, "\(field) gauge")
            XCTAssertFalse(text.main.contains("%"), "\(field) 主文含 %")
            XCTAssertFalse(text.secondary.contains("%"), "\(field) 次行含 %")
            XCTAssertFalse(text.secondary.contains("0%"))
        }
        let eight: [ReportedLimitField] = table.map { $0.0 } + [
            .provided(percent: 42, resetsAt: plus(hour), confidence: .high, corrected: false),
            .provided(percent: 42, resetsAt: nil, confidence: .stale, corrected: true),
        ]
        for field in eight {
            for cue in [ReportedLimitCue.none, .hookNotDetected, .sourceUnhealthy] {
                let text = ReportedLimitText.render(field: field, cue: cue, now: T)
                for forbidden in ["Percent unavailable", "Set estimated budget", "idle", "no active 5h window"] {
                    XCTAssertFalse(text.main.contains(forbidden), "\(field) 主文含「\(forbidden)」")
                    XCTAssertFalse(text.secondary.contains(forbidden), "\(field) 次行含「\(forbidden)」")
                }
            }
        }
        // provided 的 gauge 就是 percent
        let high = ReportedLimitText.render(field: .provided(percent: 42.25, resetsAt: nil, confidence: .high, corrected: false),
                                            cue: .none, now: T)
        XCTAssertEqual(high.main, "42.2%")   // %.1f
        XCTAssertEqual(high.gaugePercent, 42.25)
    }

    // D11:resetsAt nil 時 stale 片段仍在;.high + nil → 次行空;D23:cue 接在 stale 之後。
    func testVocabulary_StaleWithoutResetKeepsStaleMarker() {
        let stale = ReportedLimitText.render(field: .provided(percent: 42, resetsAt: nil, confidence: .stale, corrected: false),
                                             cue: .none, now: T)
        XCTAssertEqual(stale.main, "42.0%")
        XCTAssertEqual(stale.secondary, "reading is stale")
        XCTAssertEqual(stale.gaugePercent, 42)
        let high = ReportedLimitText.render(field: .provided(percent: 42, resetsAt: nil, confidence: .high, corrected: false),
                                            cue: .none, now: T)
        XCTAssertEqual(high.secondary, "")
        let cued = ReportedLimitText.render(field: .provided(percent: 42, resetsAt: nil, confidence: .stale, corrected: false),
                                            cue: .hookNotDetected, now: T)
        XCTAssertEqual(cued.secondary, "reading is stale · hook not detected")
        // corrected 不進投影次行(GUI 橘標 chrome / CLI 括號片段各自處理)
        let corrected = ReportedLimitText.render(field: .provided(percent: 42, resetsAt: nil, confidence: .stale, corrected: true),
                                                 cue: .none, now: T)
        XCTAssertEqual(corrected.secondary, "reading is stale")
    }

    // D51 now-sensitivity:同一輸入、相距 1h 的兩個 now → 兩個不同字面。
    func testVocabulary_InjectedNowControlsRelativeReset() {
        let field = ReportedLimitField.provided(percent: 42, resetsAt: T, confidence: .high, corrected: false)
        let early = ReportedLimitText.render(field: field, cue: .none, now: plus(-(2 * hour + 10 * 60)))
        let late = ReportedLimitText.render(field: field, cue: .none, now: plus(-(hour + 10 * 60)))
        XCTAssertEqual(early.secondary, "resets in 2h 10m")
        XCTAssertEqual(late.secondary, "resets in 1h 10m")
        XCTAssertFalse(early.secondary == late.secondary, "注入的 now 沒有控制 resets in …")
        // stale 變體與多日變體同樣由 now 決定
        let stale = ReportedLimitField.provided(percent: 42, resetsAt: T, confidence: .stale, corrected: false)
        XCTAssertEqual(ReportedLimitText.render(field: stale, cue: .none, now: plus(-(2 * hour + 10 * 60))).secondary,
                       "resets in 2h 10m · reading is stale")
        XCTAssertEqual(ReportedLimitText.render(field: .provided(percent: 1, resetsAt: plus(3 * day + 2 * hour), confidence: .high, corrected: false),
                                                cue: .none, now: T).secondary,
                       "resets in 3d 2h")
    }

    // D50:resetsAt == now 時 field 仍可為 provided → 次行 `resets in now`;estimate 列同理。
    func testVocabulary_ResetAtEqualsNowRendersResetsInNow() {
        let field = ReportedLimitField.provided(percent: 42, resetsAt: T, confidence: .high, corrected: false)
        let text = ReportedLimitText.render(field: field, cue: .none, now: T)
        XCTAssertEqual(text.main, "42.0%")
        XCTAssertEqual(text.secondary, "resets in now")
        XCTAssertEqual(ReportedLimitText.render(field: field, cue: .hookNotDetected, now: T).secondary,
                       "resets in now · hook not detected")
        let estimate = EstimateRowText.render(window: win(37, reset: T, .estimated, usedTokens: 370, budgetTokens: 1000),
                                              kind: .fiveHour, now: T)
        XCTAssertEqual(estimate.main, "37.0%")
        XCTAssertEqual(estimate.secondary, "370/1.0k tokens · resets in now")
    }

    // D16:estimate 列 active ⇔ claude-code ∧ official ∈ {expiredUnusable, absent};永不以 confidence 判斷。
    func testEstimateRow_ActiveOnlyWhenOfficialNotUsable() {
        XCTAssertTrue(ProviderReportedLimits.estimateActive(providerId: "claude-code", official: .expiredUnusable))
        XCTAssertTrue(ProviderReportedLimits.estimateActive(providerId: "claude-code", official: .absent))
        XCTAssertFalse(ProviderReportedLimits.estimateActive(providerId: "claude-code", official: .usable))
        for official in [OfficialWindowStatus.usable, .expiredUnusable, .absent] {
            XCTAssertFalse(ProviderReportedLimits.estimateActive(providerId: "codex", official: official))
            XCTAssertFalse(ProviderReportedLimits.estimateActive(providerId: "grok-code", official: official))
            XCTAssertFalse(ProviderReportedLimits.estimateActive(providerId: "opencode", official: official))
        }
        // 組裝載體:expiredUnusable + 估算 37% → active、EstimateRowText 給 37.0%;provider-reported 欄無 %
        let limit = ProviderLimitState(providerId: "claude-code", fiveHour: budgetEstimate,
                                       weekly: win(nil, reset: nil, .estimated, usedTokens: 370, budgetTokens: nil, windowMinutes: 10_080),
                                       fiveHourOfficial: .expiredUnusable, weeklyOfficial: .absent)
        let carrier = ProviderReportedLimits(capability: bothWindows, limit: limit, statuslinePresent: true, sourceHealth: .ok)
        XCTAssertEqual(carrier.providerId, "claude-code")
        XCTAssertTrue(carrier.fiveHourEstimateActive)
        XCTAssertTrue(carrier.weeklyEstimateActive)
        XCTAssertEqual(carrier.fiveHour, .temporarilyUnavailable(.awaitingFreshReading))
        XCTAssertEqual(carrier.weekly, .temporarilyUnavailable(.noReadingYet))
        XCTAssertEqual(carrier.cue, .none)
        XCTAssertEqual(carrier.statuslinePresent, true)
        let est = EstimateRowText.render(window: limit.fiveHour, kind: .fiveHour, now: T)
        XCTAssertEqual(est.main, "37.0%")
        XCTAssertEqual(est.secondary, "370/1.0k tokens · resets in 2h 10m")
        XCTAssertEqual(EstimateRowText.todayLine(reported: carrier, limit: limit, now: T),
                       "Estimated from local logs (your budget) · 5h: 37.0% · 370/1.0k tokens · resets in 2h 10m · weekly: 370 tokens · no budget set · rolling 7-day")
    }

    // D16:hold(official .usable、合成 0% .estimated)期間 estimate 列 inactive;Today 第 7 行為 —;合成窗永不進 estimate 列。
    func testEstimateRow_InactiveDuringUsableHoldAndNeverShowsSynthesizedWindow() {
        let hold = ProviderLimitState(providerId: "claude-code", fiveHour: synthesizedZero,
                                      weekly: win(24, reset: plus(3 * day), .high, windowMinutes: 10_080),
                                      fiveHourOfficial: .usable, weeklyOfficial: .usable)
        let carrier = ProviderReportedLimits(capability: bothWindows, limit: hold, statuslinePresent: true, sourceHealth: .ok)
        XCTAssertFalse(carrier.fiveHourEstimateActive, "hold 中 estimate 列不得啟動(即使 confidence == .estimated)")
        XCTAssertFalse(carrier.weeklyEstimateActive)
        XCTAssertEqual(carrier.fiveHour, .temporarilyUnavailable(.awaitingFreshReading))
        XCTAssertEqual(carrier.weekly, .provided(percent: 24, resetsAt: plus(3 * day), confidence: .high, corrected: false))
        XCTAssertEqual(EstimateRowText.todayLine(reported: carrier, limit: hold, now: T),
                       "Estimated from local logs (your budget) · —")
        // 非 claude 卡:—
        let codex = ProviderLimitState(providerId: "codex", fiveHour: synthesizedZero, weekly: unknownWindow,
                                       fiveHourOfficial: .usable, weeklyOfficial: .absent)
        let codexCarrier = ProviderReportedLimits(capability: bothWindows, limit: codex, statuslinePresent: nil, sourceHealth: .ok)
        XCTAssertFalse(codexCarrier.fiveHourEstimateActive)
        XCTAssertFalse(codexCarrier.weeklyEstimateActive)
        XCTAssertEqual(EstimateRowText.todayLine(reported: codexCarrier, limit: codex, now: T), "—")
        // 5h inactive、weekly active → 5h 顯 —,weekly 顯估算
        let mixed = ProviderLimitState(providerId: "claude-code", fiveHour: synthesizedZero,
                                       weekly: win(nil, reset: nil, .estimated, usedTokens: 0, budgetTokens: nil, windowMinutes: 10_080),
                                       fiveHourOfficial: .usable, weeklyOfficial: .absent)
        let mixedCarrier = ProviderReportedLimits(capability: bothWindows, limit: mixed, statuslinePresent: true, sourceHealth: .ok)
        XCTAssertFalse(mixedCarrier.fiveHourEstimateActive)
        XCTAssertTrue(mixedCarrier.weeklyEstimateActive)
        XCTAssertEqual(EstimateRowText.todayLine(reported: mixedCarrier, limit: mixed, now: T),
                       "Estimated from local logs (your budget) · 5h: — · weekly: 0 tokens · no budget set · rolling 7-day")
    }

    // D51 estimate 列 now-sensitivity。
    func testEstimateRow_InjectedNowControlsRelativeReset() {
        let window = win(37, reset: T, .estimated, usedTokens: 370, budgetTokens: 1000)
        let early = EstimateRowText.render(window: window, kind: .fiveHour, now: plus(-(2 * hour + 10 * 60)))
        let late = EstimateRowText.render(window: window, kind: .fiveHour, now: plus(-(hour + 10 * 60)))
        XCTAssertEqual(early.main, "37.0%")
        XCTAssertEqual(early.secondary, "370/1.0k tokens · resets in 2h 10m")
        XCTAssertEqual(late.secondary, "370/1.0k tokens · resets in 1h 10m")
        XCTAssertFalse(early.secondary == late.secondary, "注入的 now 沒有控制 estimate 列的 resets in …")
        // weekly 不帶 resets(rolling 7-day),與 now 無關
        let weekly = win(80, reset: nil, .estimated, usedTokens: 800, budgetTokens: 1000, windowMinutes: 10_080)
        XCTAssertEqual(EstimateRowText.render(window: weekly, kind: .weekly, now: T).secondary, "800/1.0k tokens · rolling 7-day")
        XCTAssertEqual(EstimateRowText.render(window: weekly, kind: .weekly, now: plus(-day)).secondary, "800/1.0k tokens · rolling 7-day")
    }

    // D13:Today 卡 `Set estimated budget…` predicate 四個真值組合與今日相同(不由四態驅動)。
    func testBudgetAffordance_PredicateUnchanged() {
        func snap(_ providerId: String, session: Double?) -> UsageSnapshot {
            UsageSnapshot(providerId: providerId, displayName: providerId, status: .healthy,
                          sessionUsagePercent: session, sourceDescription: "t")
        }
        func limit(_ providerId: String, _ fiveHour: LimitWindowState) -> ProviderLimitState {
            ProviderLimitState(providerId: providerId, fiveHour: fiveHour, weekly: unknownWindow)
        }
        // hold:sessionUsagePercent == 0(official 治理,設 budget 無效)→ 隱藏
        XCTAssertFalse(BudgetAffordance.todayButtonVisible(snapshot: snap("claude-code", session: 0),
                                                           limit: limit("claude-code", synthesizedZero)))
        // idle → 隱藏
        XCTAssertFalse(BudgetAffordance.todayButtonVisible(snapshot: snap("claude-code", session: nil),
                                                           limit: limit("claude-code", win(nil, reset: nil, .estimated, idle: true))))
        // 已有 budget(含 R-A5 的 budget ≤ 0)→ 隱藏
        XCTAssertFalse(BudgetAffordance.todayButtonVisible(snapshot: snap("claude-code", session: nil),
                                                           limit: limit("claude-code", win(nil, reset: nil, .estimated, usedTokens: 370, budgetTokens: 0))))
        // estimate 治理且無 budget → 顯示
        XCTAssertTrue(BudgetAffordance.todayButtonVisible(snapshot: snap("claude-code", session: nil),
                                                          limit: limit("claude-code", win(nil, reset: plus(hour), .estimated, usedTokens: 370))))
        XCTAssertTrue(BudgetAffordance.todayButtonVisible(snapshot: snap("claude-code", session: nil), limit: nil),
                      "無 limit row(從未有本機用量)仍與今日相同:顯示")
        // 非 claude 永不顯示
        XCTAssertFalse(BudgetAffordance.todayButtonVisible(snapshot: snap("codex", session: nil),
                                                           limit: limit("codex", win(nil, reset: nil, .unknown))))
    }

    // D18:第 3 列的 `no budget set` 只在 budgetTokens == nil 時出現;3b 列無 % 也無 no budget set。
    func testEstimateRow_NoBudgetSetFragmentOnlyWhenBudgetNil() {
        let budgeted = EstimateRowText.render(window: win(nil, reset: nil, .estimated, usedTokens: 0, budgetTokens: 1_000_000, windowMinutes: 10_080),
                                              kind: .weekly, now: T)
        XCTAssertEqual(budgeted.main, "0 tokens")
        XCTAssertEqual(budgeted.secondary, "rolling 7-day")
        let unbudgeted = EstimateRowText.render(window: win(nil, reset: nil, .estimated, usedTokens: 0, budgetTokens: nil, windowMinutes: 10_080),
                                                kind: .weekly, now: T)
        XCTAssertEqual(unbudgeted.main, "0 tokens")
        XCTAssertEqual(unbudgeted.secondary, "no budget set · rolling 7-day")
        // 5h:無 budget 有用量 → no budget set · resets in …;idle → idle / no active 5h window;無用量 → no local Claude usage found
        let fiveHour = EstimateRowText.render(window: win(nil, reset: plus(2 * hour + 10 * 60), .estimated, usedTokens: 800, budgetTokens: nil),
                                              kind: .fiveHour, now: T)
        XCTAssertEqual(fiveHour.main, "800 tokens")
        XCTAssertEqual(fiveHour.secondary, "no budget set · resets in 2h 10m")
        let idle = EstimateRowText.render(window: win(nil, reset: nil, .estimated, idle: true), kind: .fiveHour, now: T)
        XCTAssertEqual(idle.main, "idle")
        XCTAssertEqual(idle.secondary, "no active 5h window")
        let none = EstimateRowText.render(window: win(nil, reset: nil, .estimated), kind: .fiveHour, now: T)
        XCTAssertEqual(none.main, "no local Claude usage found")
        XCTAssertEqual(none.secondary, "")
        for (window, kind) in [(budgeted, "w"), (unbudgeted, "w"), (fiveHour, "5"), (idle, "5"), (none, "5")] {
            _ = kind
            XCTAssertFalse(window.main.contains("Percent unavailable"))
            XCTAssertFalse(window.secondary.contains("Set estimated budget"))
        }
    }

    // smoke:4 providers × 2 windows × 6 情境,推導不 crash、輸出落在契約集合內。
    func testSmoke_ProviderWindowSituationMatrix() {
        let capabilities: [(String, ReportedLimitCapability, Bool?)] = [
            ("claude-code", bothWindows, true), ("codex", bothWindows, nil),
            ("grok-code", .notProvided, nil), ("opencode", .notProvided, nil),
        ]
        // (window, official, hookOverride)
        let situations: [(String, LimitWindowState, OfficialWindowStatus, Bool??)] = [
            ("reading present", win(42, reset: plus(hour), .high), .usable, nil),
            ("absent", unknownWindow, .absent, nil),
            ("stale", win(42, reset: plus(3 * day), .stale), .usable, nil),
            ("expired-usable", synthesizedZero, .usable, nil),
            ("expired-unusable", budgetEstimate, .expiredUnusable, nil),
            ("hook missing", win(42, reset: plus(hour), .high), .usable, .some(false)),
        ]
        for (providerId, capability, hook) in capabilities {
            for kind in [LimitWindowKind.fiveHour, .weekly] {
                for (name, window, official, hookOverride) in situations {
                    let effectiveHook: Bool? = hookOverride.map { $0 } ?? hook
                    let out = derive(capability, kind, window, official, hook: effectiveHook, health: .ok)
                    let text = ReportedLimitText.render(field: out, cue: ReportedLimitField.cue(statuslinePresent: effectiveHook, sourceHealth: .ok), now: T)
                    switch capability {
                    case .notProvided:
                        XCTAssertEqual(out, .notProvidedBySource, "\(providerId) \(kind) \(name)")
                    case .provides:
                        XCTAssertFalse(out == .notProvidedBySource, "\(providerId) \(kind) \(name)")
                        XCTAssertFalse(out == .unknownCapability, "\(providerId) \(kind) \(name)")
                    }
                    if percentPayload(out) == nil {
                        XCTAssertNil(text.gaugePercent, "\(providerId) \(kind) \(name)")
                        XCTAssertFalse(text.main.contains("%"), "\(providerId) \(kind) \(name)")
                    } else {
                        XCTAssertEqual(text.main, "42.0%", "\(providerId) \(kind) \(name)")
                    }
                }
            }
        }
    }

    // 組裝接線(coordinator 是 M1 唯一組裝點,§2.2):capability / official / statuslinePresent /
    // sourceHealth 四個輸入必須各自接到正確來源。derive 本身由純函數測試窮舉;此案釘「coordinator
    // 把對的東西傳進 derive」—— 純函數測試碰不到的組裝層。
    func testDashboard_AssemblesReportedLimitsWiringPerProvider() {
        let dir = makeTempDir()
        var settings = CoreSettings()
        settings.enabledProviders = ["claude-code", "codex", "mock"]
        // claude statusline 落地檔不存在 → statuslinePresent == false(rule 4 / cue hookNotDetected)
        let missing = dir.appendingPathComponent("no-such-statusline.json")
        let claude = ClaudeCodeAdapter(roots: [], statuslineFiles: [missing], planConfigFiles: [])
        let codex = CodexAdapter(roots: [])
        let mock = MockAdapter("mock") { _ in (AdapterRefreshResult(events: [], completeness: .complete), ScanState()) }
        let coord = UsageCoordinator(dataDir: dir, settings: settings, adapters: [claude, codex, mock])
        let dash = syncDashboard(coord, now: T)

        XCTAssertEqual(dash.reportedLimits.count, 3)
        func carrier(_ pid: String) -> ProviderReportedLimits? { dash.reportedLimits.first { $0.providerId == pid } }

        // claude:capability provides、無 reading、hook 檔缺 → 兩窗 hookNotInstalled、cue hookNotDetected、
        // official absent → estimate 兩窗 active、statuslinePresent == false。
        let c = carrier("claude-code")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.statuslinePresent, false)
        XCTAssertEqual(c?.fiveHour, .temporarilyUnavailable(.hookNotInstalled))
        XCTAssertEqual(c?.weekly, .temporarilyUnavailable(.hookNotInstalled))
        XCTAssertEqual(c?.cue, .hookNotDetected)
        XCTAssertEqual(c?.fiveHourEstimateActive, true)
        XCTAssertEqual(c?.weeklyEstimateActive, true)

        // codex:capability provides、無 reading、非 claude(statuslinePresent nil、health ok)→ 兩窗 noReadingYet、
        // estimate 皆 inactive(非 claude)。
        let cx = carrier("codex")
        XCTAssertNotNil(cx)
        XCTAssertTrue(cx?.statuslinePresent == nil, "codex statuslinePresent 必為 nil")
        XCTAssertEqual(cx?.fiveHour, .temporarilyUnavailable(.noReadingYet))
        XCTAssertEqual(cx?.weekly, .temporarilyUnavailable(.noReadingYet))
        XCTAssertEqual(cx?.cue, ReportedLimitCue.none)
        XCTAssertEqual(cx?.fiveHourEstimateActive, false)
        XCTAssertEqual(cx?.weeklyEstimateActive, false)

        // mock:capability notProvided → 兩窗 notProvidedBySource(capability 接線正確;非 claude → statuslinePresent nil)。
        let mk = carrier("mock")
        XCTAssertNotNil(mk)
        XCTAssertEqual(mk?.fiveHour, .notProvidedBySource)
        XCTAssertEqual(mk?.weekly, .notProvidedBySource)
        XCTAssertTrue(mk?.statuslinePresent == nil, "mock statuslinePresent 必為 nil")
    }

    // statuslinePresent 接線的另一臂:hook 檔存在 → true、rule 7 noReadingYet(hook 在、無 reading)、cue none。
    func testDashboard_StatuslinePresentTrueWhenHookFileExists() {
        let dir = makeTempDir()
        var settings = CoreSettings()
        settings.enabledProviders = ["claude-code"]
        let statusline = dir.appendingPathComponent("claude-statusline.json")
        try? Data("{}".utf8).write(to: statusline)
        let claude = ClaudeCodeAdapter(roots: [], statuslineFiles: [statusline], planConfigFiles: [])
        let coord = UsageCoordinator(dataDir: dir, settings: settings, adapters: [claude])
        let dash = syncDashboard(coord, now: T)
        let c = dash.reportedLimits.first { $0.providerId == "claude-code" }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.statuslinePresent, true)
        XCTAssertEqual(c?.fiveHour, .temporarilyUnavailable(.noReadingYet))
        XCTAssertEqual(c?.weekly, .temporarilyUnavailable(.noReadingYet))
        XCTAssertEqual(c?.cue, ReportedLimitCue.none)
    }

    // sourceHealth 接線:refresh 拋錯 → F17 該 provider health = transientError → 四態走 rule 5
    //(sourceUnhealthy)、cue sourceUnhealthy。若組裝層把 health 傳成 nil,rule 5 跳過 → noReadingYet,測失敗。
    func testDashboard_SourceHealthWiringSurfacesUnhealthy() {
        let dir = makeTempDir()
        var settings = CoreSettings()
        settings.enabledProviders = ["codex"]
        let coord = UsageCoordinator(dataDir: dir, settings: settings, adapters: [ProvidesThrowingAdapter("codex")])
        syncRefresh(coord)   // refresh error → F17 health transientError
        let dash = syncDashboard(coord, now: T)
        let c = dash.reportedLimits.first { $0.providerId == "codex" }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.fiveHour, .temporarilyUnavailable(.sourceUnhealthy))
        XCTAssertEqual(c?.weekly, .temporarilyUnavailable(.sourceUnhealthy))
        XCTAssertEqual(c?.cue, .sourceUnhealthy)
    }

    // MARK: v0.8 A2b — Limits estimate bar single-sources EstimateRowText + injected now

    // 這次 xcheck finding 的直接重現:Limits estimate bar 的相對 reset 文字必須由注入的 `now` 控制,不碰牆鐘。
    // `EstimateBarText` 是 view 的純投影來源(view 是啞渲染);同一 window、相差 1h 的兩個 now → secondary 必變。
    func testLimitsEstimateBar_InjectedNowControlsResetText() {
        let w = budgetEstimate   // 5h、resetAt = T+2h10m、370/1000 tokens、37%
        let a = EstimateBarText.render(window: w, kind: .fiveHour, now: T)
        let b = EstimateBarText.render(window: w, kind: .fiveHour, now: plus(hour))
        XCTAssertEqual(a.secondary, "370/1.0k tokens · resets in 2h 10m")
        XCTAssertEqual(b.secondary, "370/1.0k tokens · resets in 1h 10m")
        XCTAssertFalse(a.secondary == b.secondary, "注入 now 必須控制 reset 文字,不得讀牆鐘")
        XCTAssertEqual(a.gaugePercent, 37, "gauge 由 estimate-domain usedPercent 餵")
    }

    // 單一 vocabulary source:Today / Limits / CLI 對同一 (window, kind, now) 的 main/secondary 必相同
    //(surface 可有不同 chrome,不得有不同 vocabulary)。canonical = EstimateRowText.render。
    func testEstimateVocabulary_IsIdenticalAcrossTodayLimitsAndCLI() {
        let cases: [(LimitWindowState, LimitWindowKind, String)] = [
            (budgetEstimate, .fiveHour, "budget % + reset"),
            (win(nil, reset: plus(hour), .estimated, usedTokens: 800, budgetTokens: nil), .fiveHour, "tokens + no budget"),
            (win(nil, reset: nil, .estimated, usedTokens: 0, budgetTokens: 5000, windowMinutes: 10080), .weekly, "weekly zero usage with budget"),
            (win(0, reset: nil, .estimated, idle: true), .fiveHour, "idle 5h"),
            (win(nil, reset: nil, .estimated), .fiveHour, "no local usage"),
        ]
        for (w, k, label) in cases {
            let canonical = EstimateRowText.render(window: w, kind: k, now: T)          // single source
            let limits = EstimateBarText.render(window: w, kind: k, now: T)             // Limits surface
            XCTAssertEqual(limits.main, canonical.main, label)
            XCTAssertEqual(limits.secondary, canonical.secondary, label)
            let cli = StatusRenderer.cliEstimateCell(active: true, window: w, kind: k, now: T)   // CLI surface
            let expectedCli = canonical.secondary.isEmpty ? canonical.main : "\(canonical.main) (\(canonical.secondary))"
            XCTAssertEqual(cli, expectedCli, label)
        }
        // Today surface(todayLine)嵌入同一 main/secondary
        let limit = ProviderLimitState(providerId: "claude-code", fiveHour: budgetEstimate, weekly: unknownWindow,
                                       fiveHourOfficial: .expiredUnusable, weeklyOfficial: .absent)
        let reported = ProviderReportedLimits(capability: bothWindows, limit: limit, statuslinePresent: true, sourceHealth: .ok)
        let today = EstimateRowText.todayLine(reported: reported, limit: limit, now: T)
        let canon5h = EstimateRowText.render(window: budgetEstimate, kind: .fiveHour, now: T)
        XCTAssertTrue(today.contains(canon5h.main), today)
        XCTAssertTrue(today.contains(canon5h.secondary), today)
    }

    // affordance predicate 未被 A2b refactor 偷改:沿用既有四個 truth cases(規則不重定義)。
    func testLimitsEstimateBar_BudgetAffordancePredicateUnchanged() {
        func vis(_ w: LimitWindowState, _ show: Bool) -> Bool {
            BudgetAffordance.limitsEstimateBarShowsBudgetButton(window: w, showBudgetAffordance: show)
        }
        XCTAssertTrue(vis(win(nil, reset: nil, .estimated), true), "無 %、非 idle、無 budget、claude → 顯示")
        XCTAssertFalse(vis(win(37, reset: nil, .estimated, usedTokens: 370, budgetTokens: 1000), true), "有 % → 隱藏")
        XCTAssertFalse(vis(win(0, reset: nil, .estimated, idle: true), true), "idle → 隱藏")
        XCTAssertFalse(vis(win(nil, reset: nil, .estimated, usedTokens: 800, budgetTokens: 5000), true), "有 budget → 隱藏")
        XCTAssertFalse(vis(win(nil, reset: nil, .estimated), false), "非 claude(showBudgetAffordance false)→ 隱藏")
    }
}

// MARK: - StatusRendererTests(CLI `aipet status` 的語義拆分;D14/D15/D28/D46)

private func cliDashboard(snapshots: [UsageSnapshot], limits: [ProviderLimitState],
                          reported: [ProviderReportedLimits]) -> DashboardState {
    DashboardState(generatedAt: T, snapshots: snapshots, limitStates: limits, reportedLimits: reported,
                   todayTotals: TokenBreakdown(input: 100), todayCost: .zero, todayByProvider: [],
                   burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [], topProjects: [], models: [],
                   dataQuality: [], lastRefreshAt: T)
}

private func cliSnapshot(_ providerId: String, _ displayName: String) -> UsageSnapshot {
    UsageSnapshot(providerId: providerId, displayName: displayName, status: .healthy,
                  updatedAt: T, tokenInput: 1200, tokenOutput: 340, tokenCache: 56_000, sourceDescription: "t")
}

private func carrier(_ providerId: String, fiveHour: ReportedLimitField, weekly: ReportedLimitField,
                     cue: ReportedLimitCue = .none, statuslinePresent: Bool? = nil,
                     fiveHourEstimateActive: Bool = false, weeklyEstimateActive: Bool = false) -> ProviderReportedLimits {
    ProviderReportedLimits(providerId: providerId, fiveHour: fiveHour, weekly: weekly, cue: cue,
                           statuslinePresent: statuslinePresent,
                           fiveHourEstimateActive: fiveHourEstimateActive, weeklyEstimateActive: weeklyEstimateActive)
}

private func line(_ output: String, containing needle: String) -> String? {
    output.split(separator: "\n").map(String.init).first { $0.contains(needle) }
}

/// actor `dashboard(now:)` 的同步橋(測試 harness 無 async runner;semaphore 模式與 runRefresh 一致)。
private func syncDashboard(_ coord: UsageCoordinator, now: Date) -> DashboardState {
    let sem = DispatchSemaphore(value: 0)
    var out: DashboardState?
    Task { out = await coord.dashboard(now: now); sem.signal() }
    sem.wait()
    return out!
}

private func syncRefresh(_ coord: UsageCoordinator) {
    let sem = DispatchSemaphore(value: 0)
    Task { _ = await coord.refresh(); sem.signal() }
    sem.wait()
}

/// provides-capability adapter,refresh 恆拋 → F17 health = transientError(健康度接線用)。
private final class ProvidesThrowingAdapter: ProviderAdapter {
    struct Failure: Error {}
    let providerId: String
    var reportedLimitCapability: ReportedLimitCapability { .provides(windows: [.fiveHour, .weekly]) }
    init(_ providerId: String) { self.providerId = providerId }
    var displayName: String { providerId }
    var roots: [URL] { [] }
    var watchFiles: [URL] { [] }
    var historyModel: ProviderHistoryModel { .rebuildableHistory }
    func detectAvailability() -> ProviderAvailability { ProviderAvailability(available: true, detail: "mock") }
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) { throw Failure() }
    func explainDataSources() -> String { "mock" }
    func explainRequiredPermissions() -> String { "mock" }
    func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
}

extension StatusRendererTests {

    // D28:非 provided 列 = 主文,次行非空時才接 ` — 次行`;`not provided by this source` / `—` 無破折號;
    // provided 列 = NN.N% + 括號片段;D50 `(resets in now)`。
    func testFmtWindowStateVocabulary() {
        let t3d2h = plus(3 * day + 2 * hour)
        let codex = carrier("codex", fiveHour: .temporarilyUnavailable(.noReadingYet),
                            weekly: .provided(percent: 12, resetsAt: t3d2h, confidence: .high, corrected: false))
        let grok = carrier("grok-code", fiveHour: .notProvidedBySource, weekly: .notProvidedBySource)
        let mock = carrier("mock", fiveHour: .unknownCapability, weekly: .unknownCapability)
        let claude = carrier("claude-code", fiveHour: .provided(percent: 42, resetsAt: T, confidence: .high, corrected: false),
                             weekly: .temporarilyUnavailable(.sourceUnhealthy), statuslinePresent: true)
        let dash = cliDashboard(
            snapshots: [cliSnapshot("codex", "Codex"), cliSnapshot("grok-code", "Grok"), cliSnapshot("mock", "Mock"),
                        cliSnapshot("claude-code", "Claude Code")],
            limits: [], reported: [codex, grok, mock, claude])
        let out = StatusRenderer.statusText(dashboard: dash, headline: "h", full: false, now: T)

        let codexLine = line(out, containing: "reported limits:   Codex")
        XCTAssertNotNil(codexLine, out)
        XCTAssertTrue(codexLine?.hasSuffix("5h: temporarily unavailable — no reading yet   weekly: 12.0% (resets in 3d 2h)") == true, codexLine ?? "")

        let grokLine = line(out, containing: "reported limits:   Grok source")
        XCTAssertTrue(grokLine?.hasSuffix("5h: not provided by this source   weekly: not provided by this source") == true, grokLine ?? "")
        XCTAssertFalse(grokLine?.contains(" — ") == true, "空次行不得輸出 ` — `:\(grokLine ?? "")")

        let mockLine = line(out, containing: "5h: —")
        XCTAssertTrue(mockLine?.hasSuffix("5h: —   weekly: —") == true, mockLine ?? "")

        let claudeLine = line(out, containing: "reported limits:   account-level · Claude Code")
        XCTAssertTrue(claudeLine?.contains("5h: 42.0% (resets in now)") == true, claudeLine ?? "")
        XCTAssertTrue(claudeLine?.hasSuffix("weekly: temporarily unavailable — source unhealthy — see settings → data health") == true, claudeLine ?? "")
        // 合成 post-reset 0%(`.estimated`)絕不進 provider-reported 區塊 → 四態行絕不出現 `0.0%`
        //(此列無任何 0% 載體;provenance 由 testProvenance_SynthesizedPostResetZeroIsNeverProvided 窮舉)。
        XCTAssertFalse(out.contains("0.0%"), "四態行絕不顯合成 0.0%:\(out)")
        XCTAssertFalse(out.contains("resets: "), "舊的絕對時刻 `resets:` 形狀退場")
    }

    // D14:local usage 行與 reported limits 行分離;舊 `5h:` / `weekly:` metric 行退場;burn 行不改。
    func testStatusSplitsLocalUsageFromReportedLimits() {
        let limit = ProviderLimitState(providerId: "codex",
                                       fiveHour: win(50, reset: plus(hour), .high),
                                       weekly: win(20, reset: plus(3 * day), .high, windowMinutes: 10_080),
                                       burnRateTokensPerHour: 1000, projectedExhaustionAt: plus(2 * hour), planType: "Plus",
                                       fiveHourOfficial: .usable, weeklyOfficial: .usable)
        let reported = ProviderReportedLimits(capability: bothWindows, limit: limit, statuslinePresent: nil, sourceHealth: .ok)
        let dash = cliDashboard(snapshots: [cliSnapshot("codex", "Codex")], limits: [limit], reported: [reported])
        let out = StatusRenderer.statusText(dashboard: dash, headline: "h", full: false, now: T)
        let lines = out.split(separator: "\n").map(String.init)

        XCTAssertTrue(lines.contains { $0.hasPrefix("  local usage:       1.2k in / 340 out / 56.0k cache   last data: ") }, out)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  reported limits:   Codex") && $0.hasSuffix("5h: 50.0% (resets in 1h 0m)   weekly: 20.0% (resets in 3d 0h)") }, out)
        XCTAssertTrue(lines.contains { $0.hasPrefix("  burn: 1.0k/h  → limit at ") && $0.hasSuffix("  plan: Plus") }, "burn 行不改:\(out)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("  5h:     ") }, "舊 5h metric 行退場:\(out)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("  weekly: ") }, "舊 weekly metric 行退場:\(out)")
        XCTAssertFalse(lines.contains { $0.hasPrefix("  today: ") }, "today 行改為 local usage:\(out)")
        XCTAssertFalse(out.contains("estimated (your budget)"), "codex 永無 estimate 行")
        XCTAssertFalse(out.contains("(high"), "confidence.rawValue 原字退場")
    }

    // amendment C:account-level 只出現在 claude-code 行。
    func testStatusClaudeHeaderSaysAccountLevel() {
        let claude = carrier("claude-code", fiveHour: .temporarilyUnavailable(.hookNotInstalled),
                             weekly: .temporarilyUnavailable(.hookNotInstalled), cue: .hookNotDetected, statuslinePresent: false)
        let codex = carrier("codex", fiveHour: .temporarilyUnavailable(.noReadingYet), weekly: .temporarilyUnavailable(.noReadingYet))
        let dash = cliDashboard(snapshots: [cliSnapshot("claude-code", "Claude Code"), cliSnapshot("codex", "Codex")],
                                limits: [], reported: [claude, codex])
        let out = StatusRenderer.statusText(dashboard: dash, headline: "h", full: false, now: T)
        let claudeLine = line(out, containing: "reported limits:   account-level · Claude Code")
        XCTAssertNotNil(claudeLine, out)
        XCTAssertTrue(claudeLine?.hasSuffix("5h: temporarily unavailable — statusline hook not installed   weekly: temporarily unavailable — statusline hook not installed") == true, claudeLine ?? "")
        let codexLine = line(out, containing: "reported limits:   Codex")
        XCTAssertNotNil(codexLine, out)
        XCTAssertFalse(codexLine?.contains("account-level") == true, "codex 行不得含 account-level:\(codexLine ?? "")")
        XCTAssertEqual(out.components(separatedBy: "account-level").count - 1, 1, "account-level 只出現一次")
    }

    // D15:provided .stale + corrected → `(… · reading is stale · corrected)`;corrected 恆為括號內最後片段。
    func testFmtWindowStaleAndCorrectedMarkers() {
        let t3d2h = plus(3 * day + 2 * hour)
        let claude = carrier("claude-code",
                             fiveHour: .provided(percent: 3, resetsAt: nil, confidence: .stale, corrected: true),
                             weekly: .provided(percent: 12, resetsAt: t3d2h, confidence: .stale, corrected: true),
                             cue: .hookNotDetected, statuslinePresent: false)
        let dash = cliDashboard(snapshots: [cliSnapshot("claude-code", "Claude Code")], limits: [], reported: [claude])
        let out = StatusRenderer.statusText(dashboard: dash, headline: "h", full: false, now: T)
        let claudeLine = line(out, containing: "reported limits:   account-level · Claude Code")
        XCTAssertTrue(claudeLine?.hasSuffix("5h: 3.0% (reading is stale · hook not detected · corrected)   weekly: 12.0% (resets in 3d 2h · reading is stale · hook not detected · corrected)") == true, claudeLine ?? "")
        // corrected 而無其他片段:只有 (corrected)
        let bare = carrier("codex", fiveHour: .provided(percent: 3, resetsAt: nil, confidence: .high, corrected: true),
                           weekly: .provided(percent: 4, resetsAt: nil, confidence: .high, corrected: false))
        let out2 = StatusRenderer.statusText(dashboard: cliDashboard(snapshots: [cliSnapshot("codex", "Codex")], limits: [], reported: [bare]),
                                             headline: "h", full: false, now: T)
        XCTAssertTrue(line(out2, containing: "reported limits:   Codex")?.hasSuffix("5h: 3.0% (corrected)   weekly: 4.0%") == true, out2)
    }

    // D14:`estimated (your budget):` 行只在 claude-code 且至少一窗 estimate active 時輸出;inactive 窗顯 —。
    func testStatusClaudeEstimateLineOnlyWhenActive() {
        // hold:兩窗 official usable → 無第三行
        let hold = ProviderLimitState(providerId: "claude-code", fiveHour: synthesizedZero,
                                      weekly: win(12, reset: plus(3 * day + 2 * hour), .stale, windowMinutes: 10_080),
                                      fiveHourOfficial: .usable, weeklyOfficial: .usable)
        let holdCarrier = ProviderReportedLimits(capability: bothWindows, limit: hold, statuslinePresent: true, sourceHealth: .ok)
        let holdOut = StatusRenderer.statusText(
            dashboard: cliDashboard(snapshots: [cliSnapshot("claude-code", "Claude Code")], limits: [hold], reported: [holdCarrier]),
            headline: "h", full: false, now: T)
        XCTAssertFalse(holdOut.contains("estimated (your budget)"), holdOut)
        XCTAssertTrue(holdOut.contains("5h: temporarily unavailable — awaiting fresh provider reading   weekly: 12.0% (resets in 3d 2h · reading is stale)"), holdOut)

        // 5h expiredUnusable(估算 37%)+ weekly usable → 有第三行,weekly 顯 —
        let expired = ProviderLimitState(providerId: "claude-code", fiveHour: budgetEstimate,
                                         weekly: win(12, reset: plus(3 * day + 2 * hour), .stale, windowMinutes: 10_080),
                                         fiveHourOfficial: .expiredUnusable, weeklyOfficial: .usable)
        let expiredCarrier = ProviderReportedLimits(capability: bothWindows, limit: expired, statuslinePresent: true, sourceHealth: .ok)
        let expiredOut = StatusRenderer.statusText(
            dashboard: cliDashboard(snapshots: [cliSnapshot("claude-code", "Claude Code")], limits: [expired], reported: [expiredCarrier]),
            headline: "h", full: false, now: T)
        let estimateLine = line(expiredOut, containing: "estimated (your budget):")
        XCTAssertNotNil(estimateLine, expiredOut)
        XCTAssertTrue(estimateLine?.hasSuffix("5h: 37.0% (370/1.0k tokens · resets in 2h 10m)   weekly: —") == true, estimateLine ?? "")
        XCTAssertTrue(expiredOut.contains("5h: temporarily unavailable — awaiting fresh provider reading   weekly: 12.0% (resets in 3d 2h · reading is stale)"), expiredOut)
        // estimate 行必須在 reported limits 行之後、burn 行之前
        let lines = expiredOut.split(separator: "\n").map(String.init)
        let iReported = lines.firstIndex { $0.contains("reported limits:") }!
        let iEstimate = lines.firstIndex { $0.contains("estimated (your budget):") }!
        let iBurn = lines.firstIndex { $0.hasPrefix("  burn:") }!
        XCTAssertTrue(iReported < iEstimate && iEstimate < iBurn, "行序:\(expiredOut)")

        // codex 永無
        let codex = ProviderLimitState(providerId: "codex", fiveHour: synthesizedZero, weekly: unknownWindow,
                                       fiveHourOfficial: .usable, weeklyOfficial: .absent)
        let codexCarrier = ProviderReportedLimits(capability: bothWindows, limit: codex, statuslinePresent: nil, sourceHealth: .ok)
        let codexOut = StatusRenderer.statusText(
            dashboard: cliDashboard(snapshots: [cliSnapshot("codex", "Codex")], limits: [codex], reported: [codexCarrier]),
            headline: "h", full: false, now: T)
        XCTAssertFalse(codexOut.contains("estimated (your budget)"), codexOut)
    }
}
