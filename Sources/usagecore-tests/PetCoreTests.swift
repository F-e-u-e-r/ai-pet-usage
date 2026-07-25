import Foundation
import UsageCore
import PetCore

// MARK: - FeedingEngine

final class FeedingEngineTests: XCTestCase {
    func testHungerDecay() {
        let engine = FeedingEngine(stateURL: nil, now: date("2026-01-15T08:00:00Z"))
        let start = engine.state.hunger
        engine.tick(now: date("2026-01-15T10:00:00Z"), activeMinutesToday: 0, tokensToday: 0)
        XCTAssertEqual(engine.state.hunger, start - 2 * FeedingEngine.hungerDecayPerHour, accuracy: 0.01)
    }

    func testTokenXPIsCapped() {
        let engine = FeedingEngine(stateURL: nil, now: date("2026-01-15T08:00:00Z"))
        engine.tick(now: date("2026-01-15T09:00:00Z"), activeMinutesToday: 60, tokensToday: 50_000)
        XCTAssertEqual(engine.state.xp, 50, accuracy: 0.01, "50k tokens → 50 XP")
        // 同日重複 tick 不重複計 XP
        engine.tick(now: date("2026-01-15T09:30:00Z"), activeMinutesToday: 90, tokensToday: 50_000)
        XCTAssertEqual(engine.state.xp, 50, accuracy: 0.01)
        // 巨量 token 也只到每日上限
        engine.tick(now: date("2026-01-15T10:00:00Z"), activeMinutesToday: 120, tokensToday: 900_000_000)
        XCTAssertEqual(engine.state.xp, FeedingEngine.dailyTokenXPCap, accuracy: 0.01,
                       "token XP 必須有每日上限(不獎勵揮霍)")
    }

    func testHealthyDayBonusOnRollover() {
        let engine = FeedingEngine(stateURL: nil, now: date("2026-01-15T08:00:00Z"))
        engine.tick(now: date("2026-01-15T09:00:00Z"), activeMinutesToday: 0, tokensToday: 10_000)
        let xpBefore = engine.state.xp
        // 跨日且前一日無警告 → +50
        engine.tick(now: date("2026-01-16T08:00:00Z"), activeMinutesToday: 0, tokensToday: 0)
        XCTAssertEqual(engine.state.xp, xpBefore + FeedingEngine.healthyDayBonus, accuracy: 0.01)
    }

    func testWarningCancelsHealthyBonus() {
        let engine = FeedingEngine(stateURL: nil, now: date("2026-01-15T08:00:00Z"))
        engine.tick(now: date("2026-01-15T09:00:00Z"), activeMinutesToday: 0, tokensToday: 10_000)
        engine.noteWarningSeen()
        let xpBefore = engine.state.xp
        engine.tick(now: date("2026-01-16T08:00:00Z"), activeMinutesToday: 0, tokensToday: 0)
        XCTAssertEqual(engine.state.xp, xpBefore, accuracy: 0.01, "進過 warning 的日子不該有健康加成")
    }

    func testTreatEconomyAndFeeding() {
        let engine = FeedingEngine(stateURL: nil, now: date("2026-01-15T08:00:00Z"))
        engine._test_setHunger(40)
        // 30 分鐘工作 → 1 張券
        XCTAssertEqual(engine.treatsAvailable(activeMinutesToday: 30), 1)
        // 一整天工作也封頂 6 張
        XCTAssertEqual(engine.treatsAvailable(activeMinutesToday: 600), FeedingEngine.dailyTreatCap)

        let sushi = FoodItem.starterFoods.first { $0.id == "sushi" }!
        XCTAssertEqual(engine.feed(sushi, activeMinutesToday: 30, now: date("2026-01-15T09:00:00Z")), .noTreats,
                       "券不足必須拒絕")
        XCTAssertEqual(engine.feed(sushi, activeMinutesToday: 60, now: date("2026-01-15T09:00:00Z")), .ok)
        XCTAssertEqual(engine.state.treatsSpentToday, 2)

        // 免費飼料有每日上限
        engine._test_setHunger(10)
        let kibble = FoodItem.starterFoods.first { $0.id == "kibble" }!
        for _ in 0..<FeedingEngine.dailyKibbleCap {
            engine._test_setHunger(10)
            XCTAssertEqual(engine.feed(kibble, activeMinutesToday: 0, now: date("2026-01-15T10:00:00Z")), .ok)
        }
        engine._test_setHunger(10)
        XCTAssertEqual(engine.feed(kibble, activeMinutesToday: 0, now: date("2026-01-15T10:30:00Z")), .kibbleLimitReached)

        // 吃飽了會拒絕
        engine._test_setHunger(95)
        XCTAssertEqual(engine.feed(kibble, activeMinutesToday: 0, now: date("2026-01-15T11:00:00Z")), .notHungry)
    }
}

// MARK: - MoodEngine

final class MoodEngineTests: XCTestCase {
    let now = date("2026-01-15T12:00:00Z")

    func dashboard(five: Double?, weekly: Double? = 20, warning: WarningState = .ok,
                   status: ProviderStatus = .healthy, lastEventMinutesAgo: Double = 5,
                   projectedMinutes: Double? = nil) -> DashboardState {
        let lastEvent = now.addingTimeInterval(-lastEventMinutesAgo * 60)
        let limit = ProviderLimitState(
            providerId: "codex",
            fiveHour: LimitWindowState(usedPercent: five, windowMinutes: 300, confidence: .high),
            weekly: LimitWindowState(usedPercent: weekly, windowMinutes: 10080, confidence: .high),
            burnRateTokensPerHour: 100_000,
            projectedExhaustionAt: projectedMinutes.map { now.addingTimeInterval($0 * 60) },
            lastEventAt: lastEvent,
            warning: warning
        )
        let snap = UsageSnapshot(providerId: "codex", displayName: "Codex", status: status,
                                 sourceDescription: "test")
        return DashboardState(generatedAt: now, snapshots: [snap], limitStates: [limit],
                              todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                              burnRateTokensPerHour: 100_000, burnCostPerHour: 1, hourly: [],
                              topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
    }

    func pet(hunger: Double = 80) -> PetStateData {
        var p = PetStateData(now: now)
        p.hunger = hunger
        p.lastDecayAt = now
        return p
    }

    func testPriorityOrdering() {
        // exhausted 蓋過一切(除了進食/慶祝)
        var r = MoodEngine.evaluate(dashboard: dashboard(five: 100, warning: .exhausted),
                                    pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .exhausted)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30, weekly: 85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .tired)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30, status: .stale), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .confused)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30, lastEventMinutesAgo: 60),
                                pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .sleeping)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: pet(hunger: 20), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .hungry)

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .focused, "近 10 分鐘有事件 → focused")

        r = MoodEngine.evaluate(dashboard: dashboard(five: 30, lastEventMinutesAgo: 20),
                                pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .idle)
    }

    // 同 helper 但把 5h 窗設為 estimated(其餘 .high)。
    private func dashboardEstimatedFive(_ five: Double) -> DashboardState {
        let limit = ProviderLimitState(
            providerId: "codex",
            fiveHour: LimitWindowState(usedPercent: five, windowMinutes: 300, confidence: .estimated),
            weekly: LimitWindowState(usedPercent: 20, windowMinutes: 10080, confidence: .high),
            burnRateTokensPerHour: 0, lastEventAt: now.addingTimeInterval(-300), warning: .ok)
        let snap = UsageSnapshot(providerId: "codex", displayName: "Codex", status: .healthy, sourceDescription: "t")
        return DashboardState(generatedAt: now, snapshots: [snap], limitStates: [limit],
                              todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                              burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                              topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
    }

    // MARK: - reason(item 8:為何是這個心情)

    func testWarningReasonIsProviderReportedWithValues() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)
        XCTAssertTrue(r.reason.contains("provider-reported"), r.reason)
        XCTAssertTrue(r.reason.contains("85%"), r.reason)
        XCTAssertTrue(r.reason.contains("warn at 80%"), r.reason)
        XCTAssertTrue(r.reason.contains("5-hour"), r.reason)
    }

    // provenance:estimated 的百分比絕不呈現得像 provider-reported(cross-model SEV1)。
    func testWarningReasonEstimatedNotShownAsOfficial() {
        let r = MoodEngine.evaluate(dashboard: dashboardEstimatedFive(85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)
        XCTAssertTrue(r.reason.contains("estimated"), r.reason)
        XCTAssertFalse(r.reason.contains("provider-reported"), "an estimated % must not read as provider-reported: \(r.reason)")
    }

    func testSleepingReasonIncludesIdleMinutes() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 30, lastEventMinutesAgo: 60),
                                    pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .sleeping)
        XCTAssertTrue(r.reason.contains("60"), r.reason)
        XCTAssertTrue(r.reason.lowercased().contains("idle"), r.reason)
    }

    func testHungryReasonUsesFullness() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: pet(hunger: 20), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .hungry)
        XCTAssertTrue(r.reason.contains("Fullness 20%"), r.reason)
    }

    func testExhaustedReasonHasWindowValueProvenance() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 100, warning: .exhausted),
                                    pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .exhausted)
        XCTAssertTrue(r.reason.contains("provider-reported"), r.reason)
        XCTAssertTrue(r.reason.contains("100%"), r.reason)
        XCTAssertTrue(r.reason.contains("limit reached"), r.reason)
        XCTAssertTrue(r.reason.contains("5-hour"), r.reason)
    }

    // codex SEV1:exhausted 也可能來自 estimated budget → 絕不呈現得像官方事實。
    func testExhaustedEstimatedNotShownAsOfficial() {
        let limit = ProviderLimitState(
            providerId: "claude-code",
            fiveHour: LimitWindowState(usedPercent: 100, windowMinutes: 300, confidence: .estimated),
            weekly: LimitWindowState(usedPercent: 20, windowMinutes: 10080, confidence: .high),
            burnRateTokensPerHour: 0, lastEventAt: now.addingTimeInterval(-300), warning: .exhausted)
        let snap = UsageSnapshot(providerId: "claude-code", displayName: "Claude Code", status: .healthy, sourceDescription: "t")
        let dash = DashboardState(generatedAt: now, snapshots: [snap], limitStates: [limit],
                                  todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                  burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                  topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: dash, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .exhausted)
        XCTAssertTrue(r.reason.contains("estimated"), r.reason)
        XCTAssertFalse(r.reason.contains("provider-reported"), "estimated exhaustion must not read as official: \(r.reason)")
    }

    // codex SEV1(round-2):排名須用原始 Double。claude-code 99.6% 與 codex 100.0% 四捨五入後皆 100;
    // 若以 Int 排名會平手 → providerId「claude-code」誤勝;以原始值排名則 codex(100.0)勝出。
    func testExhaustedRanksRawDoubleNotRounded() {
        func lim(_ pid: String, _ five: Double) -> ProviderLimitState {
            ProviderLimitState(providerId: pid,
                fiveHour: LimitWindowState(usedPercent: five, windowMinutes: 300, confidence: .high),
                weekly: LimitWindowState(usedPercent: 10, windowMinutes: 10080, confidence: .high),
                burnRateTokensPerHour: 0, lastEventAt: now.addingTimeInterval(-300), warning: .exhausted)
        }
        let snaps = [UsageSnapshot(providerId: "claude-code", displayName: "Claude Code", status: .healthy, sourceDescription: "t"),
                     UsageSnapshot(providerId: "codex", displayName: "Codex", status: .healthy, sourceDescription: "t")]
        let dash = DashboardState(generatedAt: now, snapshots: snaps,
                                  limitStates: [lim("claude-code", 99.6), lim("codex", 100.0)],
                                  todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                  burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                  topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: dash, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .exhausted)
        XCTAssertTrue(r.reason.hasPrefix("CX"), "raw ranking must name codex (100.0), not claude-code (99.6): \(r.reason)")
        XCTAssertTrue(r.reason.contains("+1 more"), r.reason)
    }

    func testNoProvidersReasonDistinctFromSleeping() {
        let empty = DashboardState(generatedAt: now, snapshots: [], limitStates: [],
                                   todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                   burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                   topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: empty, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .confused, "empty snapshots → confused, not sleeping")
        XCTAssertEqual(r.reason, "No providers detected yet.")
    }

    func testErrorReasonSeparateFromStale() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 30, status: .error), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .confused)
        XCTAssertTrue(r.reason.lowercased().contains("couldn't be read") || r.reason.lowercased().contains("read"), r.reason)
        XCTAssertFalse(r.reason.lowercased().contains("stale"), "an error is not the same as stale: \(r.reason)")
    }

    func testEveryMoodHasNonEmptyReason() {
        func check(_ d: DashboardState, _ p: PetStateData, _ label: String) {
            let r = MoodEngine.evaluate(dashboard: d, pet: p, warnThreshold: 80, now: now)
            XCTAssertFalse(r.reason.isEmpty, "\(label) → \(r.mood) has empty reason")
            XCTAssertFalse(r.shortReason.isEmpty, "\(label) → \(r.mood) has empty shortReason")
        }
        var eatingPet = pet(); eatingPet.eatingUntil = now.addingTimeInterval(60)
        var celebPet = pet(); celebPet.celebrationUntil = now.addingTimeInterval(60)
        var happyPet = pet(); happyPet.happyUntil = now.addingTimeInterval(60)
        check(dashboard(five: 30), eatingPet, "eating")
        check(dashboard(five: 30), celebPet, "celebration")
        check(dashboard(five: 100, warning: .exhausted), pet(), "exhausted")
        check(dashboard(five: 85), pet(), "warning")
        check(dashboard(five: 30, weekly: 85), pet(), "tired")
        check(dashboard(five: 30, status: .stale), pet(), "confused-stale")
        check(dashboard(five: 30, status: .error), pet(), "confused-error")
        check(dashboard(five: 30, lastEventMinutesAgo: 60), pet(), "sleeping")
        check(dashboard(five: 30), pet(hunger: 20), "hungry")
        check(dashboard(five: 30, lastEventMinutesAgo: 5), happyPet, "happy")
        check(dashboard(five: 30, lastEventMinutesAgo: 5), pet(), "focused")
        check(dashboard(five: 30, lastEventMinutesAgo: 20), pet(), "idle")
    }

    // 泡泡 shortReason 誠實守則:estimated 的百分比一律帶 `~`+`est` 標記(絕不裸露官方外觀)。
    func testShortReasonEstimatedIsMarked() {
        let r = MoodEngine.evaluate(dashboard: dashboardEstimatedFive(85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)
        XCTAssertTrue(r.shortReason.contains("est"), r.shortReason)
        XCTAssertTrue(r.shortReason.contains("~"), r.shortReason)
        XCTAssertTrue(r.shortReason.contains("85%"), r.shortReason)
    }

    // provider-reported 是官方真值,short 可裸露 %(且**不得**被標成 estimated)。
    func testShortReasonProviderReportedIsBare() {
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 85), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)
        XCTAssertTrue(r.shortReason.contains("85%"), r.shortReason)
        XCTAssertFalse(r.shortReason.contains("est"), "official value must not be tagged estimated: \(r.shortReason)")
        XCTAssertFalse(r.shortReason.contains("~"), r.shortReason)
    }

    func testTiredWeeklyReasonCarriesProvenance() {
        let limit = ProviderLimitState(
            providerId: "claude-code",
            fiveHour: LimitWindowState(usedPercent: 10, windowMinutes: 300, confidence: .high),
            weekly: LimitWindowState(usedPercent: 88, windowMinutes: 10080, confidence: .estimated),
            burnRateTokensPerHour: 0, lastEventAt: now.addingTimeInterval(-300), warning: .ok)
        let snap = UsageSnapshot(providerId: "claude-code", displayName: "Claude Code", status: .healthy, sourceDescription: "t")
        let dash = DashboardState(generatedAt: now, snapshots: [snap], limitStates: [limit],
                                  todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                  burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                  topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: dash, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .tired)
        XCTAssertTrue(r.reason.contains("weekly"), r.reason)
        XCTAssertTrue(r.reason.contains("estimated"), r.reason)
        XCTAssertTrue(r.reason.contains("88%"), r.reason)
    }

    func testWarningTriggerPicksHighestProvider() {
        func lim(_ pid: String, _ five: Double) -> ProviderLimitState {
            ProviderLimitState(providerId: pid,
                fiveHour: LimitWindowState(usedPercent: five, windowMinutes: 300, confidence: .high),
                weekly: LimitWindowState(usedPercent: 10, windowMinutes: 10080, confidence: .high),
                burnRateTokensPerHour: 0, lastEventAt: now.addingTimeInterval(-300), warning: .ok)
        }
        let snaps = [UsageSnapshot(providerId: "codex", displayName: "Codex", status: .healthy, sourceDescription: "t"),
                     UsageSnapshot(providerId: "claude-code", displayName: "Claude Code", status: .healthy, sourceDescription: "t")]
        let dash = DashboardState(generatedAt: now, snapshots: snaps,
                                  limitStates: [lim("codex", 82), lim("claude-code", 90)],
                                  todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                  burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                  topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: dash, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .warning)
        XCTAssertTrue(r.reason.contains("90%"), "names the highest (90%), not 82%: \(r.reason)")
        XCTAssertFalse(r.reason.contains("82%"), r.reason)
    }

    func testTransientStatesBeatEverything() {
        var p = pet()
        p.eatingUntil = now.addingTimeInterval(3)
        var r = MoodEngine.evaluate(dashboard: dashboard(five: 100, warning: .exhausted),
                                    pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .eating)

        p = pet()
        p.celebrationUntil = now.addingTimeInterval(60)
        r = MoodEngine.evaluate(dashboard: dashboard(five: 5), pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .celebration)
    }

    func testBurnRateDrivesAnimationSpeed() {
        // 預計 20 分鐘後耗盡 → 最躁動
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 70, projectedMinutes: 20),
                                    pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.animationSpeed, 2.0, accuracy: 0.01)
        let calm = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(calm.animationSpeed, 1.0, accuracy: 0.21)
    }

    func testNoDataMakesConfused() {
        let snap = UsageSnapshot(providerId: "codex", displayName: "Codex", status: .noData,
                                 sourceDescription: "test")
        let dash = DashboardState(generatedAt: now, snapshots: [snap], limitStates: [],
                                  todayTotals: .zero, todayCost: .zero, todayByProvider: [],
                                  burnRateTokensPerHour: 0, burnCostPerHour: 0, hourly: [],
                                  topProjects: [], models: [], dataQuality: [], lastRefreshAt: now)
        let r = MoodEngine.evaluate(dashboard: dash, pet: pet(), warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .confused)
    }

    // 慶祝要署名(2026-07-16 實測:無歸因的「quota reset」被誤認成別家 provider 的官方重置)。
    func testCelebrationAttributionOfficialAndEstimated() {
        var p = pet()
        p.celebrationUntil = now.addingTimeInterval(60)
        p.celebrationProviderId = "codex"
        p.celebrationWindow = "5h"
        p.celebrationEstimated = false
        var r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .celebration)
        XCTAssertEqual(r.reason, "CX 5-hour window just reset — celebrating.")
        XCTAssertEqual(r.shortReason, "CX 5h reset!")

        // 估算邊界:絕不讀起來像官方重置
        p.celebrationProviderId = "claude-code"
        p.celebrationEstimated = true
        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.reason, "CC 5-hour block likely reset (estimated) — celebrating.")
        XCTAssertEqual(r.shortReason, "CC 5h ~reset")
        XCTAssertFalse(r.reason.contains("window just reset"),
                       "估算邊界不得讀起來像官方重置:\(r.reason)")

        p.celebrationWindow = "weekly"
        p.celebrationEstimated = false
        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.reason, "CC weekly window just reset — celebrating.")
        XCTAssertEqual(r.shortReason, "CC wk reset!")
    }

    func testCelebrationWithoutAttributionFallsBackGeneric() {
        var p = pet()
        p.celebrationUntil = now.addingTimeInterval(60)
        let r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertEqual(r.mood, .celebration)
        XCTAssertEqual(r.reason, "A quota just reset — celebrating.")
        XCTAssertEqual(r.shortReason, "quota reset!")
    }

    // codex SEV1 round-2(F6):summary 會進匯出報告 → 百分比必須帶信度標記,
    // 估算/陳舊值不得裸露成官方數字;估算慶祝的前綴也不得讀起來像官方。
    func testSummaryMarksEstimatedPercentAndCelebrationPrefix() {
        // estimated 5h(dashboardEstimatedFive 的 5h 信度 = .estimated)
        var r = MoodEngine.evaluate(dashboard: dashboardEstimatedFive(42), pet: pet(),
                                    warnThreshold: 80, now: now)
        XCTAssertTrue(r.summary.contains("CX ~42% est"), r.summary)
        XCTAssertFalse(r.summary.contains("CX 42% "), "估算百分比不得裸露:\(r.summary)")
        // provider-reported 維持裸值
        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: pet(), warnThreshold: 80, now: now)
        XCTAssertTrue(r.summary.contains("CX 30%"), r.summary)
        // 估算慶祝前綴
        var p = pet()
        p.celebrationUntil = now.addingTimeInterval(60)
        p.celebrationProviderId = "claude-code"
        p.celebrationWindow = "5h"
        p.celebrationEstimated = true
        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertTrue(r.summary.hasPrefix("Quota likely reset (est)! "), r.summary)
        p.celebrationEstimated = false
        r = MoodEngine.evaluate(dashboard: dashboard(five: 30), pet: p, warnThreshold: 80, now: now)
        XCTAssertTrue(r.summary.hasPrefix("Quota reset! "), r.summary)
    }

    // codex SEV1 round-2(F3):celebration 的自動泡泡必須用 shortReason(署名歸因),
    // 罐頭 "quota reset!" 正是 2026-07-16 誤導事故的表面。
    func testAutoPhraseCelebrationUsesShortReason() {
        XCTAssertEqual(PetSpeech.autoPhrase(for: .celebration, shortReason: "CX 5h reset!", tick: 3),
                       "CX 5h reset!")
        XCTAssertEqual(PetSpeech.autoPhrase(for: .celebration, shortReason: "CC 5h ~reset", tick: 0),
                       "CC 5h ~reset")
        // shortReason 空(理論上不發生)→ 回退罐頭台詞而非空泡泡
        XCTAssertNotNil(PetSpeech.autoPhrase(for: .celebration, shortReason: "", tick: 1))
        // 其他心情照舊輪播;睡覺不吵
        XCTAssertEqual(PetSpeech.autoPhrase(for: .eating, shortReason: "x", tick: 1), "nom nom!")
        XCTAssertNil(PetSpeech.autoPhrase(for: .sleeping, shortReason: "x", tick: 0))
    }

    /// 舊版 pet-state.json(無歸因欄位)必須照常解碼(新欄位皆 optional → decodeIfPresent)。
    func testPetStateBackwardCompatibleDecodeWithoutCelebrationFields() throws {
        var p = pet(hunger: 42)
        p.celebrationUntil = now.addingTimeInterval(60)
        let data = try JSONEncoder().encode(p)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // 模擬舊檔:移除三個新欄位
        obj.removeValue(forKey: "celebrationProviderId")
        obj.removeValue(forKey: "celebrationWindow")
        obj.removeValue(forKey: "celebrationEstimated")
        let legacy = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(PetStateData.self, from: legacy)
        XCTAssertEqual(decoded.hunger, 42)
        XCTAssertNil(decoded.celebrationProviderId)
        XCTAssertNil(decoded.celebrationWindow)
        XCTAssertNil(decoded.celebrationEstimated)
    }
}

// MARK: - Coordinator 整合冒煙測試(fixtures → refresh → dashboard → 匯出)

final class CoordinatorIntegrationTests: XCTestCase {
    func testEndToEndRefreshAndExport() throws {
        // 以 fixtures 建立假的 provider 根目錄
        let claudeRoot = makeTempDir()
        let claudeProj = claudeRoot.appendingPathComponent("-Users-dev-projects-demo-app")
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("claude-session.jsonl"),
                                         to: claudeProj.appendingPathComponent("s.jsonl"))
        let codexRoot = makeTempDir()
        let codexDay = codexRoot.appendingPathComponent("2026/01/15")
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("codex-rollout.jsonl"),
                                         to: codexDay.appendingPathComponent("rollout-2026-01-15T09-00-00-x.jsonl"))

        let dataDir = makeTempDir()
        let coordinator = UsageCoordinator(
            dataDir: dataDir,
            settings: CoreSettings(claudeFiveHourTokenBudget: 1_000_000),
            adapters: [CodexAdapter(roots: [codexRoot]), ClaudeCodeAdapter(roots: [claudeRoot], statuslineFiles: [], planConfigFiles: [])]
        )

        let expectation = DispatchSemaphore(value: 0)
        Task {
            let outcome = await coordinator.refresh()
            XCTAssertEqual(outcome.dashboard.snapshots.count, 2)
            XCTAssertGreaterThan(outcome.insertedEvents, 0)

            // 兩個 provider 都有 limit 狀態;codex 讀值已過期(fixture 是過去日期)→ estimated 0%
            let codexLimit = outcome.dashboard.limitStates.first { $0.providerId == "codex" }!
            XCTAssertEqual(codexLimit.fiveHour.confidence, .estimated)
            XCTAssertEqual(codexLimit.fiveHour.usedPercent, 0)

            // 範圍查詢涵蓋 fixture 日期 → 專案彙總存在
            let range = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-16T00:00:00Z"))
            let page = await coordinator.projectPage(range: range)
            XCTAssertGreaterThan(page.projects.count, 0)
            XCTAssertEqual(page.projects.first!.projectName, "demo-app")

            // 匯出範圍報告
            let out = dataDir.appendingPathComponent("report.html")
            try? await coordinator.exportReport(kind: .range(range, title: "Test Report"), to: out)
            let html = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            XCTAssertTrue(html.contains("<h2>Projects</h2>"))
            XCTAssertTrue(html.contains("demo-app"))
            XCTAssertFalse(html.contains("/Users/dev/projects/demo-app"), "報告不得含完整路徑")

            // 第二個 coordinator 重用同一 dataDir:帳本與掃描進度應持久化(增量 0 新事件)
            let coordinator2 = UsageCoordinator(
                dataDir: dataDir,
                settings: CoreSettings(),
                adapters: [CodexAdapter(roots: [codexRoot]), ClaudeCodeAdapter(roots: [claudeRoot], statuslineFiles: [], planConfigFiles: [])]
            )
            let outcome2 = await coordinator2.refresh()
            XCTAssertEqual(outcome2.insertedEvents, 0, "重啟後不得重複匯入")

            expectation.signal()
        }
        expectation.wait()
    }

    func testFullReindexPreservesUnavailableProviderHistory() throws {
        let codexRoot = makeTempDir()
        let codexDay = codexRoot.appendingPathComponent("2026/01/15")
        try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("codex-rollout.jsonl"),
                                         to: codexDay.appendingPathComponent("rollout-2026-01-15T09-00-00-x.jsonl"))

        let dataDir = makeTempDir()
        let missingClaudeRoot = dataDir.appendingPathComponent("missing-claude-root")
        try? FileManager.default.removeItem(at: missingClaudeRoot)

        let ledger = UsageLedger(fileURL: dataDir.appendingPathComponent("ledger.jsonl"))
        let unavailableEvent = UsageEvent(
            id: "cc:preseed-unavailable",
            providerId: "claude-code",
            modelId: "claude-sonnet-4-5",
            timestamp: Date().addingTimeInterval(-3600),
            tokens: TokenBreakdown(input: 123),
            sourceKind: "test"
        )
        let staleCodexEvent = UsageEvent(
            id: "cx:stale-before-reindex",
            providerId: "codex",
            modelId: "gpt-5-codex",
            timestamp: Date().addingTimeInterval(-1800),
            tokens: TokenBreakdown(input: 456),
            sourceKind: "test"
        )
        XCTAssertEqual(ledger.append([unavailableEvent, staleCodexEvent]), 2)

        var reindexSettings = CoreSettings()
        reindexSettings.retentionDays = 100_000   // 固定舊 fixture(2026-01-15)不被保留期修剪(codex C-MF6:reindex 現套用保留期 cutoff)
        let coordinator = UsageCoordinator(
            dataDir: dataDir,
            settings: reindexSettings,
            adapters: [
                CodexAdapter(roots: [codexRoot]),
                ClaudeCodeAdapter(roots: [missingClaudeRoot], statuslineFiles: [], planConfigFiles: [])
            ]
        )

        let expectation = DispatchSemaphore(value: 0)
        Task {
            let outcome = await coordinator.refresh(fullReindex: true)
            let reloaded = UsageLedger(fileURL: dataDir.appendingPathComponent("ledger.jsonl"))

            XCTAssertTrue(reloaded.events.contains { $0.id == unavailableEvent.id },
                          "unavailable provider history must survive a full reindex")
            XCTAssertFalse(reloaded.events.contains { $0.id == staleCodexEvent.id },
                           "available provider history should be cleared before reimport")
            XCTAssertTrue(reloaded.events.contains { $0.providerId == "codex" && $0.sourceKind == "codex-rollout" },
                          "available provider events should be rebuilt")
            XCTAssertTrue(outcome.dashboard.dataQuality.contains {
                $0 == "claude-code: history kept — provider unavailable during full reindex"
            })

            expectation.signal()
        }
        expectation.wait()
    }

    func testWatchPlanWatchesExistingDirsAndStatuslineTriggers() throws {
        let codexRoot = makeTempDir()   // 存在
        let missing = makeTempDir().appendingPathComponent("nope-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: missing)   // 確保不存在
        let statusDir = makeTempDir()   // statusline 檔的存在父目錄
        let statusFile = statusDir.appendingPathComponent("claude-statusline.json")
        let coordinator = UsageCoordinator(
            dataDir: makeTempDir(), settings: CoreSettings(),
            adapters: [CodexAdapter(roots: [codexRoot]),
                       ClaudeCodeAdapter(roots: [missing], statuslineFiles: [statusFile], planConfigFiles: [])]
        )
        let expectation = DispatchSemaphore(value: 0)
        Task {
            let plan = await coordinator.watchPlan()
            // 監看目錄:存在的 codex 目錄 + statusline 的存在父目錄;不含不存在的 claude 目錄
            XCTAssertTrue(plan.dirs.contains(codexRoot.path), "existing provider dir should be watched")
            XCTAssertTrue(plan.dirs.contains(statusDir.path), "statusline parent dir should be watched")
            XCTAssertFalse(plan.dirs.contains(missing.path), "missing dir must be excluded")
            // 觸發白名單:provider 目錄 + statusline 檔精確路徑
            XCTAssertTrue(plan.triggers.contains(codexRoot.path))
            XCTAssertTrue(plan.triggers.contains(statusFile.path), "statusline file should be a trigger")
            // 語意更新(grok 預設啟用後):未安裝的 provider(根目錄不存在)沒有可監看目標,
            // 不再擋下慢速 fallback;否則預設啟用而未安裝者會讓使用者永遠停在快速輪詢。
            XCTAssertTrue(plan.allEnabledRootsWatched, "a missing-root (uninstalled) provider must not block the slow fallback")
            expectation.signal()
        }
        expectation.wait()
    }
}

// MARK: - UsageRingModel(R2 B1/B2 幾何與過濾契約)

final class UsageRingModelTests: XCTestCase {
    private func limit(_ id: String, fiveHour: Double?) -> ProviderLimitState {
        ProviderLimitState(
            providerId: id,
            fiveHour: LimitWindowState(usedPercent: fiveHour, windowMinutes: 300,
                                       confidence: fiveHour == nil ? .unknown : .high),
            weekly: LimitWindowState(windowMinutes: 10080, confidence: .unknown)
        )
    }

    /// 過濾:nil 跳過(Grok 現況)、順序保留、上限 capacity。
    func testEntriesFilterOrderAndCap() {
        let entries = UsageRingModel.entries(from: [
            limit("claude-code", fiveHour: 41),
            limit("codex", fiveHour: 4),
            limit("grok-code", fiveHour: nil),
        ])
        XCTAssertEqual(entries.map(\.providerId), ["claude-code", "codex"])
        XCTAssertEqual(entries.map(\.percent), [41, 4])

        let five = (0..<6).map { limit("p\($0)", fiveHour: Double($0)) }
        XCTAssertEqual(UsageRingModel.entries(from: five).count, UsageRingModel.capacity)

        XCTAssertTrue(UsageRingModel.entries(from: [limit("grok-code", fiveHour: nil)]).isEmpty)
    }

    /// 幾何:自 sprite 淨空向外疊(第一家最外),絕不向內縮;最內環 = base。
    func testDiametersGrowOutwardFromSpriteClearBase() {
        let s = 96.0
        let base = UsageRingModel.baseDiameter(petSize: s)
        XCTAssertEqual(base, 168, "1.75 × 96")
        // 兩家:第 0 家(外)= base+13、第 1 家(內)= base。
        XCTAssertEqual(UsageRingModel.diameter(index: 0, count: 2, petSize: s), base + 13)
        XCTAssertEqual(UsageRingModel.diameter(index: 1, count: 2, petSize: s), base)
        // 單家 = base;四家最外 = base+39 = 容量外徑。
        XCTAssertEqual(UsageRingModel.diameter(index: 0, count: 1, petSize: s), base)
        XCTAssertEqual(UsageRingModel.diameter(index: 0, count: 4, petSize: s),
                       UsageRingModel.capacityOuterDiameter(petSize: s))
        // 最內環永不小於 base(不回蓋 sprite;codex P1 的幾何釘)。
        for n in 1...4 {
            XCTAssertEqual(UsageRingModel.diameter(index: n - 1, count: n, petSize: s), base)
        }
    }

    /// 面板尺寸下限:容量外徑 + 邊距(64pt 全範圍不裁;數值對齊計畫 v3)。
    func testCapacityOuterDiameterAcrossSizes() {
        XCTAssertEqual(UsageRingModel.capacityOuterDiameter(petSize: 64), 64 * 1.75 + 39)
        XCTAssertEqual(UsageRingModel.capacityOuterDiameter(petSize: 160), 160 * 1.75 + 39)
    }
}

// MARK: - Finding 1:漫遊「游標懸停暫停」純判定(讓移動中的寵物可抓)

final class WanderCursorPauseTests: XCTestCase {
    func testPauseWhenCursorOverAndNotClickThrough() {
        XCTAssertTrue(WanderBand.shouldPauseWanderForCursor(cursorOverPanel: true, clickThrough: false),
                      "游標在寵物上且可互動 → 暫停漫遊(視窗停住可抓)")
    }
    func testNoPauseWhenClickThrough() {
        XCTAssertFalse(WanderBand.shouldPauseWanderForCursor(cursorOverPanel: true, clickThrough: true),
                       "click-through:游標穿透、無法拖曳 → 不暫停(否則無故凍在游標下)")
    }
    func testNoPauseWhenCursorAway() {
        XCTAssertFalse(WanderBand.shouldPauseWanderForCursor(cursorOverPanel: false, clickThrough: false))
    }
}

// MARK: - Finding 2:menu 面板 reset 欄壓縮標籤(去截字 + a11y 完整)

final class ResetLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    func testCountdownForms() {
        XCTAssertEqual(ResetLabel.countdown(to: nil, now: now), "—")
        XCTAssertEqual(ResetLabel.countdown(to: at(-5), now: now), "now")
        XCTAssertEqual(ResetLabel.countdown(to: at(0), now: now), "now")
        XCTAssertEqual(ResetLabel.countdown(to: at(59 * 60), now: now), "59m")
        XCTAssertEqual(ResetLabel.countdown(to: at(4 * 3600 + 59 * 60), now: now), "4h 59m")
        XCTAssertEqual(ResetLabel.countdown(to: at(48 * 3600), now: now), "48h 0m", "48h 邊界仍走時制")
        XCTAssertEqual(ResetLabel.countdown(to: at(49 * 3600), now: now), "2d 1h", ">48h 進位日制")
        XCTAssertEqual(ResetLabel.countdown(to: at(6 * 86400 + 3 * 3600), now: now), "6d 3h")
    }

    func testCompactPrecedenceAndPrefix() {
        XCTAssertEqual(ResetLabel.compact(fiveHourResetAt: at(4 * 3600 + 59 * 60),
                                          weeklyResetAt: at(6 * 86400), now: now),
                       "4h 59m", "5h 有重置 → 純倒數,無前綴")
        XCTAssertEqual(ResetLabel.compact(fiveHourResetAt: nil,
                                          weeklyResetAt: at(6 * 86400 + 3 * 3600), now: now),
                       "wk 6d 3h", "5h 無、weekly 有 → wk 前綴")
        XCTAssertEqual(ResetLabel.compact(fiveHourResetAt: nil, weeklyResetAt: nil, now: now), "—")
    }

    func testCompactWorstCaseFitsBudget() {
        let worst = ResetLabel.compact(fiveHourResetAt: nil,
                                       weeklyResetAt: at(6 * 86400 + 23 * 3600), now: now)
        XCTAssertEqual(worst, "wk 6d 23h")
        XCTAssertTrue(worst.count <= 9, "壓縮後最壞情況 \(worst.count) 字元,應 ≤ 9(固定窄欄放得下不截)")
    }

    func testAccessibilityFullSentence() {
        XCTAssertEqual(ResetLabel.accessibility(fiveHourResetAt: at(4 * 3600), weeklyResetAt: nil, now: now),
                       "5-hour limit resets in 4h 0m")
        XCTAssertEqual(ResetLabel.accessibility(fiveHourResetAt: nil, weeklyResetAt: at(6 * 86400), now: now),
                       "weekly limit resets in 6d 0h")
        XCTAssertEqual(ResetLabel.accessibility(fiveHourResetAt: nil, weeklyResetAt: nil, now: now),
                       "no reset scheduled")
    }
}

// MARK: - Menu 面板欄寬(100% 三位數截字修復)

final class MenuPanelMetricsTests: XCTestCase {
    // 重現痕跡:原欄寬寫死 50pt;本機實測 "wk 100%" 內容寬印於測試輸出(修復前 > 50 → 截字)。
    func testWindowColumnFitsWorstCase() {
        let worst = MenuPanelMetrics.worstWindowCellWidth
        print("measured worst window cell = \(worst)pt (old hardcoded column = 50pt)")
        XCTAssertTrue(MenuPanelMetrics.windowColumnWidth >= worst + 1,
                      "欄寬必須 ≥ worst-case 內容 + 呼吸:\(MenuPanelMetrics.windowColumnWidth) vs \(worst)")
        // 釘住 100% 案例本身(修復的觸發器):三位數 cell 不得超過欄寬
        XCTAssertTrue(MenuPanelMetrics.measuredWindowCellWidth(label: "wk", value: "100%")
                        <= MenuPanelMetrics.windowColumnWidth,
                      "wk 100% 必須放得進欄寬")
    }

    func testPanelWidthAccommodatesColumns() {
        // 總和含 header 水平 padding 16(.padding(.horizontal, 8)×2)—— 上一版公式與本測試
        // 都漏了它(雙審查者各自抓到);此處刻意鏡寫公式:改任一側都必須是自覺的。
        let minimum = 110 + 2 * MenuPanelMetrics.windowColumnWidth
            + MenuPanelMetrics.resetColumnWidth + 4 * 8 + 16 + 12
        XCTAssertTrue(MenuPanelMetrics.panelWidth >= minimum,
                      "面板寬 \(MenuPanelMetrics.panelWidth) 必須 ≥ 欄位總和 \(minimum)")
        XCTAssertTrue(MenuPanelMetrics.panelWidth >= 340, "不小於原設計寬(外觀不回退)")
    }
}
