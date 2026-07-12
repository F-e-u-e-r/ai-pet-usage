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

        let coordinator = UsageCoordinator(
            dataDir: dataDir,
            settings: CoreSettings(),
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
