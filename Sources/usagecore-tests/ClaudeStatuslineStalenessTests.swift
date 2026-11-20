import Foundation
@testable import UsageCore

/// Claude Code statusline 讀數的「誠實陳舊度」:Claude Code desktop(Code tab)的 headless
/// stream-json session 不呼叫 statusLine 指令,hook 可能數小時不寫檔 —— 舊讀數不得冒充即時值。
final class ClaudeStatuslineStalenessTests: XCTestCase {
    let settings = CoreSettings()   // 無 budget:估算路徑不給百分比

    // MARK: (a) 5h:reset 已過 / 無 reset 且 >5h → unknown

    func testFiveHourPastResetIsUnknownNotRecoveredZero() {
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T10:30:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 24, windowMinutes: 10080,
                                              resetsAt: date("2026-01-18T10:00:00Z")))
        _ = engine.ingestTransitions(readings: [reading], settings: settings)
        let ledger = UsageLedger(fileURL: nil)   // 帳本看不到 claude.ai 等共用額度的用量
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: settings,
                                      now: date("2026-01-15T11:00:00Z"))
        XCTAssertNil(state.fiveHour.usedPercent,
                     "5h reset 已過、沒有新讀數 → 未知;不得顯示 44%,也不得捏造 recovered 0%")
        XCTAssertEqual(state.fiveHourOfficial, .expiredUnusable)
        XCTAssertEqual(state.weekly.usedPercent, 24, "週窗仍在期內 → 保留數值")
    }

    func testFiveHourWithoutResetIsUnknownOnceOlderThanFiveHours() {
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300, resetsAt: nil),
            secondary: nil)
        _ = engine.ingestTransitions(readings: [reading], settings: settings)
        let ledger = UsageLedger(fileURL: nil)
        let within = engine.limitState(providerId: "claude-code", ledger: ledger, settings: settings,
                                       now: date("2026-01-15T14:59:00Z"))
        XCTAssertEqual(within.fiveHour.usedPercent, 44, "5h 內的讀數照常顯示")
        let old = engine.limitState(providerId: "claude-code", ledger: ledger, settings: settings,
                                    now: date("2026-01-15T15:01:00Z"))
        XCTAssertNil(old.fiveHour.usedPercent, "無 resets_at 且讀數 >5h → 未知")
        XCTAssertEqual(old.fiveHourOfficial, .expiredUnusable)
    }

    // MARK: observedAt = captured_at(fallback mtime)

    func testRateLimitObservedAtUsesCapturedAtNotMtime() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("claude-statusline.json")
        try #"{"schema_version":1,"captured_at":"2026-01-15T10:00:00Z","rate_limits":{"five_hour":{"used_percentage":6},"seven_day":{"used_percentage":39}}}"#
            .data(using: .utf8)!.write(to: file)   // mtime = 現在
        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [file])
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.observedAt, date("2026-01-15T10:00:00Z"),
                       "複製/touch 檔案不得讓舊讀數看起來是新的")

        let noCaptured = dir.appendingPathComponent("legacy.json")
        try #"{"rate_limits":{"five_hour":{"used_percentage":6}}}"#.data(using: .utf8)!.write(to: noCaptured)
        let legacy = ClaudeCodeAdapter.readStatuslineRateLimits(from: [noCaptured])
        XCTAssertTrue(abs(legacy.first!.observedAt.timeIntervalSinceNow) < 60, "缺 captured_at → mtime")
    }

    // MARK: (c) model_scoped 沿用項保留自己的原始時間

    func testCarriedModelScopedEntryKeepsItsOwnObservedAt() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("claude-statusline.json")
        try #"""
        {"schema_version":1,"captured_at":"2026-01-15T10:00:00Z",
         "rate_limits":{"seven_day":{"used_percentage":39}},
         "model_scoped":[{"display_name":"Fable","used_percentage":41,"observed_at":"2026-01-15T00:00:00Z"},
                         {"display_name":"Other","used_percentage":5}]}
        """#.data(using: .utf8)!.write(to: file)
        let scoped = ClaudeCodeAdapter.readModelScopedLimits(from: [file])
        XCTAssertEqual(scoped.first { $0.displayName == "Fable" }?.observedAt, date("2026-01-15T00:00:00Z"),
                       "沿用的舊 Fable 不得借用新檔的 captured_at")
        XCTAssertEqual(scoped.first { $0.displayName == "Other" }?.observedAt, date("2026-01-15T10:00:00Z"))
    }

    // MARK: hook 端到端

    private func runHook(dataDir: URL, payload: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("Scripts/claude-statusline-hook.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["AIPET_DATA_DIR"] = dataDir.path
        env.removeValue(forKey: "AIPET_STATUSLINE_HOOK_ACTIVE")
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(payload.data(using: .utf8)!)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private static let seededFile = #"{"schema_version":1,"captured_at":"2026-01-15T00:00:00Z","model":null,"rate_limits":{"five_hour":{"used_percentage":9},"seven_day":{"used_percentage":30}},"model_scoped":[{"display_name":"Fable","used_percentage":41}]}"#

    func testHookCarriesModelScopedWithOriginalTimestamp() throws {
        let dataDir = makeTempDir()
        let landed = dataDir.appendingPathComponent("claude-statusline.json")
        try Self.seededFile.data(using: .utf8)!.write(to: landed)
        try runHook(dataDir: dataDir,
                    payload: #"{"rate_limits":{"five_hour":{"used_percentage":6},"seven_day":{"used_percentage":39}}}"#)
        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [landed])
        XCTAssertEqual(readings.first?.primary?.usedPercent, 6, "新的帳戶窗照常落地")
        let scoped = ClaudeCodeAdapter.readModelScopedLimits(from: [landed])
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.usedPercent, 41)
        XCTAssertEqual(scoped.first?.observedAt, date("2026-01-15T00:00:00Z"),
                       "沿用的 Fable 必須帶原始時間,app 才能標示其年齡")

        // 第二次沿用:時間仍是最初那一筆,不得被中間那份檔的 captured_at 洗新
        try runHook(dataDir: dataDir,
                    payload: #"{"rate_limits":{"five_hour":{"used_percentage":7}}}"#)
        XCTAssertEqual(ClaudeCodeAdapter.readModelScopedLimits(from: [landed]).first?.observedAt,
                       date("2026-01-15T00:00:00Z"))
    }

    func testHookPayloadWithoutRateLimitsKeepsPreviousFile() throws {
        let dataDir = makeTempDir()
        let landed = dataDir.appendingPathComponent("claude-statusline.json")
        try Self.seededFile.data(using: .utf8)!.write(to: landed)
        try runHook(dataDir: dataDir, payload: #"{"model":{"id":"claude-fable-5","display_name":"Fable"}}"#)
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), Self.seededFile,
                       "payload 缺 rate_limits → 保留上一份好檔(不得用空 rate_limits + 新 captured_at 覆蓋)")
    }

    // MARK: (b) 週窗 / model-scoped:保留數值,超過 30 分鐘標示年齡

    func testAsOfLabelThreshold() {
        let t = date("2026-01-15T10:00:00Z")
        XCTAssertNil(StatuslineAge.asOfLabel(observedAt: nil, now: t))
        XCTAssertNil(StatuslineAge.asOfLabel(observedAt: t, now: t))
        XCTAssertNil(StatuslineAge.asOfLabel(observedAt: t, now: t.addingTimeInterval(30 * 60)), "門檻含 30 分鐘")
        XCTAssertEqual(StatuslineAge.asOfLabel(observedAt: t, now: t.addingTimeInterval(31 * 60)), "as of 31m ago")
        XCTAssertEqual(StatuslineAge.asOfLabel(observedAt: t, now: t.addingTimeInterval(10 * 3600 + 59)), "as of 10h ago")
        XCTAssertEqual(StatuslineAge.asOfLabel(observedAt: t, now: t.addingTimeInterval(2 * 86400)), "as of 2d ago")
        XCTAssertNil(StatuslineAge.asOfLabel(observedAt: t.addingTimeInterval(3600), now: t), "未來時間(時鐘偏差)不標示")
    }

    func testWeeklyAndScopedValuesKeepValueButCarryAge() {
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T00:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 6, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T03:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 39, windowMinutes: 10080,
                                              resetsAt: date("2026-01-19T00:00:00Z")))
        _ = engine.ingestTransitions(readings: [reading], settings: settings)
        let now = date("2026-01-15T10:00:00Z")
        var state = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: now)
        XCTAssertNil(state.fiveHour.usedPercent, "5h reset 已過 → 未知")
        XCTAssertEqual(state.weekly.usedPercent, 39, "週窗保留數值")
        XCTAssertEqual(StatuslineAge.weeklyAsOfLabel(for: state, now: now), "as of 10h ago")

        state.modelScopedWeekly = [ModelScopedLimitWindow(displayName: "Fable", usedPercent: 41,
                                                          resetsAt: nil, observedAt: date("2026-01-14T22:00:00Z"))]
        let fable = ClaudeScopedDisplay.expandLimitStates([state]).first { $0.providerId == ClaudeScopedDisplay.fableId }
        XCTAssertEqual(fable?.weekly.usedPercent, 41)
        XCTAssertEqual(fable.flatMap { StatuslineAge.weeklyAsOfLabel(for: $0, now: now) }, "as of 12h ago")

        let fresh = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T00:20:00Z"))
        XCTAssertNil(StatuslineAge.weeklyAsOfLabel(for: fresh, now: date("2026-01-15T00:20:00Z")), "30 分鐘內不標示")
    }

    func testWidgetRowMarksOnlyStaleClaudeWeekly() {
        let now = date("2026-01-15T10:00:00Z")
        let old = date("2026-01-15T00:00:00Z")
        let limits = [
            ProviderLimitState(providerId: "claude-code",
                               fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
                               weekly: LimitWindowState(usedPercent: 39, windowMinutes: 10_080,
                                                        confidence: .stale, observedAt: old)),
            ProviderLimitState(providerId: "codex",
                               fiveHour: LimitWindowState(usedPercent: 7, windowMinutes: 300, confidence: .high),
                               weekly: LimitWindowState(usedPercent: 35, windowMinutes: 10_080,
                                                        confidence: .stale, observedAt: old)),
        ]
        let dash = DashboardState(generatedAt: now, snapshots: [], limitStates: limits, todayTotals: .zero,
                                  todayCost: .zero, todayByProvider: [], burnRateTokensPerHour: 0,
                                  burnCostPerHour: 0, hourly: [], topProjects: [], models: [],
                                  dataQuality: [], lastRefreshAt: now)
        let rows = WidgetSnapshotBuilder.build(dashboard: dash, limitStates: limits,
                                               enabledProviders: ["claude-code", "codex"]).rows
        let claude = rows.first { $0.providerId == "claude-code" }
        XCTAssertEqual(claude?.weeklyPercent, 39)
        XCTAssertNil(claude?.fiveHourPercent ?? nil, "5h 未知 → widget 不給數字")
        XCTAssertEqual(claude?.weeklyAsOf, old)
        XCTAssertNil(rows.first { $0.providerId == "codex" }?.weeklyAsOf ?? nil, "非 Claude 列不標示")
    }
}
