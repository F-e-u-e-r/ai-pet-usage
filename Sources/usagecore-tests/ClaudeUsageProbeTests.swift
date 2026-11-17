import Foundation
@testable import UsageCore

/// `claude /usage` 探針:畫面還原、解析、落地檔與 adapter 併入。
/// 畫面 fixture 取自 2026-11-16 實際擷取(只留額度段落)。
final class ClaudeUsageProbeTests: XCTestCase {

    private func date(_ s: String) -> Date { ISO8601.parse(s)! }

    /// 實擷取的額度段落(已還原文字)。
    private let realScreen = """
     ❯ /usage
     Current session
     ████████████████████████▌                          49% used
     Resets 11:59am (Asia/Tokyo)
     Current week (all models)
     ██████████████████████▌                            45% used
     Resets Nov 20 at 7am (Asia/Tokyo)
     Current week (Fable)
     █████████████████████                              42% used
     Resets Nov 20 at 7am (Asia/Tokyo)
     What's contributing to your usage?
     50%  Check which models your subagents use
    """

    func testRenderTextTurnsCursorMovesIntoSpaces() {
        // 真實位元組形狀:字與字之間是 ESC[nG(絕對欄位),不是空白。
        let raw = Data("\u{1B}[3G\u{1B}[38;5;220m45%\u{1B}[8Gused\u{1B}]0;title\u{07}\r\nResets\u{1B}[1C11:59am".utf8)
        let text = ClaudeUsageProbe.renderText(raw)
        XCTAssertTrue(text.contains("45% used"), "ESC[nG must become a space: \(text)")
        XCTAssertTrue(text.contains("Resets 11:59am"), "ESC[nC must become a space: \(text)")
        XCTAssertFalse(text.contains("title"), "OSC payload must be stripped")
    }

    func testParseRealScreenLimits() {
        let now = date("2026-11-16T01:00:00Z")
        guard let p = ClaudeUsageProbe.parse(screen: realScreen, now: now) else {
            XCTAssertNotNil(nil, "real screen must parse"); return
        }
        XCTAssertEqual(p.session?.usedPercent, 49)
        XCTAssertEqual(p.session?.resetsAt, date("2026-11-16T02:59:00Z"))
        XCTAssertEqual(p.week?.usedPercent, 45)
        XCTAssertEqual(p.week?.resetsAt, date("2026-11-19T22:00:00Z"))
        XCTAssertEqual(p.scoped.map(\.displayName), ["Fable"])
        XCTAssertEqual(p.scoped.first?.window.usedPercent, 42)
    }

    func testParseUsesLastFrameNotCachedFirstFrame() {
        let stale = realScreen.replacingOccurrences(of: "49% used", with: "10% used")
        let fresh = realScreen.replacingOccurrences(of: "49% used", with: "51% used")
        let p = ClaudeUsageProbe.parse(screen: stale + "\n Refreshing…\n" + fresh, now: date("2026-11-16T01:00:00Z"))
        XCTAssertEqual(p?.session?.usedPercent, 51)
    }

    func testParseSessionWithNoUsageHasNoReset() {
        // 實擷取:窗內尚無用量時只顯示 "0% used",沒有 Resets 行。
        let screen = " Current session\n 0% used\n Current week (all models)\n ███ 46% used\n Resets Nov 20 at 6:59am (Asia/Tokyo)\n"
        let p = ClaudeUsageProbe.parse(screen: screen, now: date("2026-11-16T02:00:00Z"))
        XCTAssertEqual(p?.session?.usedPercent, 0)
        XCTAssertNil(p?.session?.resetsAt)
        XCTAssertEqual(p?.week?.resetsAt, date("2026-11-19T21:59:00Z"))
    }

    func testParseNeverFabricates() {
        let now = date("2026-11-16T01:00:00Z")
        XCTAssertNil(ClaudeUsageProbe.parse(screen: "", now: now))
        XCTAssertNil(ClaudeUsageProbe.parse(
            screen: " Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n", now: now),
            "trust prompt must not produce a reading")
        XCTAssertNil(ClaudeUsageProbe.parse(
            screen: " Current session\n Loading…\n Current week (all models)\n Loading…\n", now: now),
            "headers without percents must not become 0%")
        XCTAssertNil(ClaudeUsageProbe.usedPercent(in: "99999% used"), "absurd percent rejected")
    }

    func testParseResetFormats() {
        let early = date("2026-11-16T01:00:00Z")
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11:59am (Asia/Tokyo)", now: early),
                       date("2026-11-16T02:59:00Z"))
        // 時刻已過 → 明天。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11:59am (Asia/Tokyo)", now: date("2026-11-16T03:30:00Z")),
                       date("2026-11-17T02:59:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 12am (UTC)", now: early),
                       date("2026-11-17T00:00:00Z"), "12am is midnight")
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Nov 20 at 6:59am (Asia/Tokyo)", now: early),
                       date("2026-11-19T21:59:00Z"))
        // 跨年。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Jan 2 at 7am (UTC)", now: date("2026-12-30T10:00:00Z")),
                       date("2027-01-02T07:00:00Z"))
        // 畫面截斷的時區 / 垃圾 → nil(不猜)。
        XCTAssertNil(ClaudeUsageProbe.parseReset("Resets 7am (Asia/Toky)", now: early))
        XCTAssertNil(ClaudeUsageProbe.parseReset("Resets soon", now: early))
        XCTAssertNil(ClaudeUsageProbe.parseReset("Resets 13pm (UTC)", now: early))
    }

    func testShouldProbeOnlyWhenEverySourceIsStale() {
        let now = date("2026-11-16T02:00:00Z")
        XCTAssertTrue(ClaudeUsageProbe.shouldProbe(capturedAts: [nil, nil], now: now), "no readings → probe")
        XCTAssertFalse(ClaudeUsageProbe.shouldProbe(
            capturedAts: [now.addingTimeInterval(-60), nil], now: now), "fresh statusline → skip")
        XCTAssertFalse(ClaudeUsageProbe.shouldProbe(
            capturedAts: [now.addingTimeInterval(-3600), now.addingTimeInterval(-120)], now: now),
            "fresh probe reading → skip")
        XCTAssertTrue(ClaudeUsageProbe.shouldProbe(
            capturedAts: [now.addingTimeInterval(-3600), now.addingTimeInterval(-301)], now: now), "both stale → probe")
        XCTAssertTrue(ClaudeUsageProbe.shouldProbe(
            capturedAts: [now.addingTimeInterval(86_400)], now: now), "future timestamp cannot prove freshness")
    }

    func testProbeLandingMergesIntoAdapterAndBeatsCarriedFable() throws {
        let dir = makeTempDir()
        let probeAt = date("2026-11-16T02:00:00Z")
        let probe = dir.appendingPathComponent(ClaudeUsageProbe.landingFileName)
        guard let parsed = ClaudeUsageProbe.parse(screen: realScreen, now: probeAt) else {
            XCTAssertNotNil(nil, "real screen must parse"); return
        }
        try ClaudeUsageProbe.writeLanding(parsed, capturedAt: probeAt, to: probe)
        let mode = try FileManager.default.attributesOfItem(atPath: probe.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600, "landing file must be owner-only")

        // hook 檔:captured_at 比探針新(之後某次終端機訊息),但 Fable 是沿用的舊項(observed_at 很舊)。
        let hook = dir.appendingPathComponent("claude-statusline.json")
        try Data("""
        {"schema_version":1,"captured_at":"2026-11-16T02:10:00Z",
         "rate_limits":{"five_hour":{"used_percentage":55,"resets_at":1794798000},
                        "seven_day":{"used_percentage":47,"resets_at":1795125600}},
         "model_scoped":[{"display_name":"Fable","used_percentage":41,"observed_at":"2026-11-15T23:36:35Z"}]}
        """.utf8).write(to: hook)

        let scoped = ClaudeCodeAdapter.readModelScopedLimits(from: [hook, probe])
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.usedPercent, 42, "probe's Fable is newer than the carried hook entry")
        XCTAssertEqual(scoped.first?.observedAt, probeAt)

        // 5h / 週:hook 較新 → hook 勝;探針只在 hook 陳舊時接手。
        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [hook, probe])
        XCTAssertEqual(readings.first?.primary?.usedPercent, 55)
        let older = ClaudeCodeAdapter.readStatuslineRateLimits(from: [probe])
        XCTAssertEqual(older.first?.primary?.usedPercent, 49)
        XCTAssertEqual(older.first?.secondary?.usedPercent, 45)
        XCTAssertEqual(older.first?.observedAt, probeAt)
    }

    func testDefaultStatuslineFilesKeepDiagnosticIds() {
        let adapter = ClaudeCodeAdapter()
        XCTAssertEqual(adapter.statuslineFiles.last?.lastPathComponent, ClaudeUsageProbe.landingFileName)
        let ids = adapter.diagnosticSources().filter { $0.id != .claudeProjects }
        XCTAssertEqual(ids.first { $0.id == .claudeStatuslineOurHook }?.url.lastPathComponent, "claude-statusline.json")
        XCTAssertEqual(ids.first { $0.id == .claudeStatuslineShared }?.url.lastPathComponent, "usage-status.json")
    }

    // MARK: - 2026-11-16 審查修正(sol / Fable / Argon / Claude hunter)

    func testParseIgnoresLinesFromUnknownSections() {
        let now = date("2026-11-16T02:00:00Z")
        // 週窗 0% 無 Resets,後面的 "Extra usage" 段的重置時間不得被算進週窗。
        let a = " Current session\n 0% used\n Current week (all models)\n 0% used\n Extra usage\n ████ 20% used\n Resets Dec 1 at 12am (Asia/Tokyo)\n"
        let pa = ClaudeUsageProbe.parse(screen: a, now: now)
        XCTAssertEqual(pa?.week?.usedPercent, 0)
        XCTAssertNil(pa?.week?.resetsAt, "Extra usage reset must not attach to the weekly window")
        // 週窗仍在 Loading… → 不得拿 Extra usage 的 20% 當週窗(造值)。
        let b = " Current session\n 5% used\n Resets 3pm (Asia/Tokyo)\n Current week (all models)\n Loading…\n Extra usage\n ████ 20% used\n Resets Dec 1 at 12am (Asia/Tokyo)\n"
        let pb = ClaudeUsageProbe.parse(screen: b, now: now)
        XCTAssertEqual(pb?.session?.usedPercent, 5)
        XCTAssertNil(pb?.week, "a loading weekly window must stay missing, not borrow another section's percent")
        let c = " Current session\n 5% used\n Current week (Fable)\n Loading…\n Extra usage\n 12% used\n"
        XCTAssertEqual(ClaudeUsageProbe.parse(screen: c, now: now)?.scoped.count, 0)
    }

    func testUsedPercentRejectsSeparatedNumbers() {
        XCTAssertNil(ClaudeUsageProbe.usedPercent(in: "1,234% used"), "must not read 234")
        XCTAssertEqual(ClaudeUsageProbe.usedPercent(in: "███ 1.5% used"), 1.5)
        XCTAssertNil(ClaudeUsageProbe.usedPercent(in: "-5% used"), "must not read 5")
        XCTAssertNil(ClaudeUsageProbe.usedPercent(in: "-0.5% used"))
    }

    func testParseResetEdgeDates() {
        // 顯示的那一分鐘內 → 仍是今天(馬上重置),不是 24h 後。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11:59am (Asia/Tokyo)", now: date("2026-11-16T02:59:05Z")),
                       date("2026-11-16T02:59:00Z"))
        // 過了那一分鐘 → 明天。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11:59am (Asia/Tokyo)", now: date("2026-11-16T03:00:30Z")),
                       date("2026-11-17T02:59:00Z"))
        // 新年剛過看到 Dec 31 → 去年那個,不是明年底。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Dec 31 at 11pm (UTC)", now: date("2027-01-01T05:00:00Z")),
                       date("2026-12-31T23:00:00Z"))
        XCTAssertNil(ClaudeUsageProbe.parseReset("Resets Nov 31 at 7am (UTC)", now: date("2026-11-16T01:00:00Z")),
                     "impossible date must not roll into Dec 1")
    }

    func testRenderTextBreaksLinesOnRowMoves() {
        let raw = Data("Current session\u{1B}[2;1H49% used\u{1B}[5;3HCurrent week (all models)\u{1B}[6;1H45% used\u{1B}P1$r0m\u{1B}\\".utf8)
        let text = ClaudeUsageProbe.renderText(raw)
        XCTAssertFalse(text.contains("1$r"), "DCS payload must be stripped: \(text)")
        let p = ClaudeUsageProbe.parse(screen: text, now: date("2026-11-16T01:00:00Z"))
        XCTAssertEqual(p?.session?.usedPercent, 49)
        XCTAssertEqual(p?.week?.usedPercent, 45, "row move must separate the weekly header: \(text)")
    }

    func testProbeEnvironmentKeepsOnlyClaudeConfigDir() {
        let env = ClaudeUsageProbe.probeEnvironment(
            binary: URL(fileURLWithPath: "/x/bin/claude"), home: URL(fileURLWithPath: "/Users/u"),
            parent: ["CLAUDE_CONFIG_DIR": "/cfg/a", "CLAUDE_CODE_CHILD_SESSION": "1", "ANTHROPIC_BASE_URL": "http://x"])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/cfg/a")
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
    }

    func testFreshnessStampsUseCapturedAtThenMtime() throws {
        let dir = makeTempDir()
        let ours = dir.appendingPathComponent("a.json")
        try Data(#"{"captured_at":"2026-11-16T01:00:00Z","rate_limits":{"seven_day":{"used_percentage":40}}}"#.utf8).write(to: ours)
        let shared = dir.appendingPathComponent("usage-status.json")   // 官方 payload 原文:無 captured_at
        try Data(#"{"rate_limits":{"five_hour":{"used_percentage":3}}}"#.utf8).write(to: shared)
        let mtime = date("2026-11-16T01:58:00Z")
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: shared.path)
        let junk = dir.appendingPathComponent("junk.json")   // 空殼 rate_limits + 新 captured_at:不能證明新鮮
        try Data(#"{"captured_at":"2026-11-16T01:59:00Z","rate_limits":{}}"#.utf8).write(to: junk)
        let stamps = ClaudeUsageProbe.freshnessStamps(of: [ours, shared, junk, dir.appendingPathComponent("missing.json")])
        XCTAssertEqual(stamps[0], date("2026-11-16T01:00:00Z"))
        XCTAssertEqual(stamps[1], mtime, "shared statusline without captured_at falls back to mtime")
        XCTAssertNil(stamps[2]); XCTAssertNil(stamps[3])
        XCTAssertFalse(ClaudeUsageProbe.shouldProbe(capturedAts: stamps, now: date("2026-11-16T02:00:00Z")),
                       "a fresh shared statusline must suppress the probe")
    }

    // MARK: 假 claude(sh 腳本)驅動真正的 captureScreen

    private func fakeClaude(_ body: String) throws -> URL {
        let url = makeTempDir().appendingPathComponent("claude")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url
    }

    /// 快取頁(10%)+ Refreshing;重繪如實反映當下狀態;只做差異更新(spinner)。
    private func refreshingFake(freshAfterTicks: Int?) -> String {
        let finish = freshAfterTicks.map { "[ $i -ge \($0) ] && [ $S = 0 ] && { S=1; printf '\\033[2;1H51\\033[4;1H46\\033[5;1H\\033[K'; }" } ?? ":"
        return """
        S=0
        draw() { if [ $S = 0 ]; then printf '\\033[2J\\033[HCurrent session\\r\\n10%% used\\r\\nCurrent week (all models)\\r\\n45%% used\\r\\n* Refreshing...\\r\\n'; else printf '\\033[2J\\033[HCurrent session\\r\\n51%% used\\r\\nCurrent week (all models)\\r\\n46%% used\\r\\n'; fi; }
        trap draw WINCH
        draw
        i=0
        while true; do sleep 0.1; i=$((i+1)); printf '\\033[5;1H%s' "$((i % 4))"; \(finish); done
        """
    }

    func testCaptureWaitsForRefreshToFinish() throws {
        let bin = try fakeClaude(refreshingFake(freshAfterTicks: 40))   // 約 4s 後才拿到新值
        let home = makeTempDir()
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: home, timeout: 15)
        let p = screen.flatMap { ClaudeUsageProbe.parse(screen: $0, now: Date()) }
        XCTAssertEqual(p?.session?.usedPercent, 51, "cached 10% must never be returned as current")
        XCTAssertEqual(p?.week?.usedPercent, 46)
    }

    func testCaptureGivesUpWhileStillRefreshing() throws {
        let bin = try fakeClaude(refreshingFake(freshAfterTicks: nil))
        let t0 = Date()
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 5)
        XCTAssertNil(screen, "still refreshing at the deadline → no reading")
        XCTAssertTrue(Date().timeIntervalSince(t0) < 10, "bounded by timeout + teardown")
    }

    private func isAlive(pidFile: URL) -> Bool? {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return kill(pid, 0) == 0
    }

    /// 子孫忽略 TERM/HUP(像不聽話的 hook)。
    private func stubbornChildFake(pidFile: URL, printsNumbers: Bool) -> String {
        let frame = printsNumbers ? "printf '\\033[2J\\033[HCurrent session\\r\\n5%% used\\r\\n'" : ":"
        return """
        sh -c 'trap "" TERM HUP INT; echo $$ > "\(pidFile.path)"; while true; do sleep 1; done' &
        trap '\(frame.replacingOccurrences(of: "'", with: "'\\''"))' WINCH
        \(frame)
        while true; do sleep 0.1; done
        """
    }

    func testCaptureTeardownKillsStubbornDescendants() throws {
        let pidFile = makeTempDir().appendingPathComponent("child.pid")
        let bin = try fakeClaude(stubbornChildFake(pidFile: pidFile, printsNumbers: true))
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 8)
        XCTAssertNotNil(screen)
        usleep(200_000)
        XCTAssertEqual(isAlive(pidFile: pidFile), false, "TERM-ignoring descendant must not survive teardown")
    }

    func testCancelKillsProbeGroupAndWritesNothing() throws {
        let pidFile = makeTempDir().appendingPathComponent("child.pid")
        let bin = try fakeClaude(stubbornChildFake(pidFile: pidFile, printsNumbers: false))
        let landing = makeTempDir().appendingPathComponent(ClaudeUsageProbe.landingFileName)
        let handle = ClaudeUsageProbe.ProbeHandle()
        let done = DispatchSemaphore(value: 0)
        var wrote = true
        let t0 = Date()
        DispatchQueue.global().async {
            wrote = ClaudeUsageProbe.runOnce(binary: bin, home: makeTempDir(), landing: landing, handle: handle)
            done.signal()
        }
        usleep(1_000_000)
        XCTAssertEqual(isAlive(pidFile: pidFile), true, "fixture: child started")
        handle.cancel()
        usleep(100_000)
        XCTAssertEqual(isAlive(pidFile: pidFile), false, "cancel() must SIGKILL the whole group synchronously")
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "capture must end promptly after cancel")
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: landing.path))
        XCTAssertTrue(Date().timeIntervalSince(t0) < 6)
        // 已取消的把手 → 根本不 spawn。
        XCTAssertNil(ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), handle: handle))
    }


    /// 重繪頁先送片段(只有 5h 快取值)、停頓 0.4s、再送其餘含 Refreshing 的部分。
    func testCaptureRejectsQuietFragmentOfRefreshingPage() throws {
        let bin = try fakeClaude("""
        S=0
        draw() { if [ $S = 0 ]; then printf '\\033[2J\\033[HCurrent session\\r\\n10%% used\\r\\n'; sleep 0.4; printf 'Current week (all models)\\r\\n45%% used\\r\\n* Refreshing...\\r\\n'; else printf '\\033[2J\\033[HCurrent session\\r\\n51%% used\\r\\nCurrent week (all models)\\r\\n46%% used\\r\\n'; fi; }
        trap draw WINCH
        draw
        i=0
        while true; do sleep 0.1; i=$((i+1)); [ $i -ge 50 ] && S=1; done
        """)
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 15)
        let p = screen.flatMap { ClaudeUsageProbe.parse(screen: $0, now: Date()) }
        XCTAssertTrue(p?.session?.usedPercent != 10, "a quiet fragment of a refreshing page must not be accepted")
        XCTAssertEqual(p?.session?.usedPercent, 51)
    }

    func testParseResetRepeatedDSTHour() {
        // 2026-11-01 紐約 1:00–2:00 出現兩次;05:45Z 是第一次的 1:45 EDT,1:30am 的第二次是 06:30Z。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 1:30am (America/New_York)", now: date("2026-11-01T05:45:00Z")),
                       date("2026-11-01T06:30:00Z"))
        // 帶日期的同一時刻也要取尚未過去的第二次。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Nov 1 at 1:30am (America/New_York)", now: date("2026-11-01T05:45:00Z")),
                       date("2026-11-01T06:30:00Z"))
        // Lord Howe 只回撥 30 分鐘:14:50Z = 1:50 LHDT,1:45am 的第二次是 15:15Z,不是明天。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 1:45am (Australia/Lord_Howe)", now: date("2026-04-04T14:50:00Z")),
                       date("2026-04-04T15:15:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Apr 5 at 1:45am (Australia/Lord_Howe)", now: date("2026-04-04T14:50:00Z")),
                       date("2026-04-04T15:15:00Z"))
        // 兩次都過了 → 明天。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 1:30am (America/New_York)", now: date("2026-11-01T06:45:00Z")),
                       date("2026-11-02T06:30:00Z"))
        // 超過 4h 的回撥(1969 Kwajalein 換日線回撥 23h)也要找到第二次。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Sep 30 at 1:30am (Pacific/Kwajalein)", now: date("1969-09-30T13:00:00Z")),
                       date("1969-09-30T13:30:00Z"))
        // 回撥前一天的同一時刻不是重複時刻,只有一次。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets Oct 31 at 1:30am (America/New_York)", now: date("2026-10-31T05:45:00Z")),
                       date("2026-10-31T05:30:00Z"))
        // 春令當天 3:45 EDT 看到 "2:30am" → 明天的 2:30 EST(06:30Z),不是今天被挪成 3:30 後 +1 天。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 2:30am (America/New_York)", now: date("2026-03-08T07:45:00Z")),
                       date("2026-03-09T06:30:00Z"))
        // 2010 Casey 由 +11 回撥到 +8,牆上時鐘從 3/5 02:00 退回 3/4 23:00(跨午夜)。
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 12:30am (Antarctica/Casey)", now: date("2010-03-04T15:00:00Z")),
                       date("2010-03-04T16:30:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11:30pm (Antarctica/Casey)", now: date("2010-03-04T13:30:00Z")),
                       date("2010-03-04T15:30:00Z"))
    }

    func testParseResetSkipsNonexistentGapTime() {
        let ny230 = "Resets 2:30am (America/New_York)"
        XCTAssertEqual(ClaudeUsageProbe.parseReset(ny230, now: date("2026-03-08T06:00:00Z")),
                       date("2026-03-09T06:30:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset(ny230, now: date("2026-03-08T06:59:00Z")),
                       date("2026-03-09T06:30:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset(ny230, now: date("2026-03-08T07:45:00Z")),
                       date("2026-03-09T06:30:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 3:30am (America/New_York)", now: date("2026-03-08T06:00:00Z")),
                       date("2026-03-08T07:30:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11am (Pacific/Apia)", now: date("2011-12-29T21:00:00Z")),
                       date("2011-12-29T21:00:00Z"))
        XCTAssertEqual(ClaudeUsageProbe.parseReset("Resets 11am (Pacific/Apia)", now: date("2011-12-29T22:30:00Z")),
                       date("2011-12-30T21:00:00Z"))
    }

    private func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    func testAdapterDistrustsFutureCapturedAt() throws {
        let dir = makeTempDir()
        let now = date("2026-11-16T12:00:00Z")
        let hook = dir.appendingPathComponent("hook.json")
        let probe = dir.appendingPathComponent("probe.json")
        let future = isoUTC(now.addingTimeInterval(30 * 86400))
        let atNow = isoUTC(now)
        try Data(#"{"schema_version":1,"captured_at":"\#(future)","rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20}}}"#.utf8).write(to: hook)
        try Data(#"{"schema_version":1,"captured_at":"\#(atNow)","rate_limits":{"five_hour":{"used_percentage":55},"seven_day":{"used_percentage":60}}}"#.utf8).write(to: probe)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: hook.path)

        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [hook, probe], now: now)
        XCTAssertEqual(readings.first(where: { $0.primary != nil })?.primary?.usedPercent, 55)
        XCTAssertEqual(readings.first(where: { $0.secondary != nil })?.secondary?.usedPercent, 60)

        let hookWin = dir.appendingPathComponent("hook-win.json")
        let probeOld = dir.appendingPathComponent("probe-old.json")
        try Data(#"{"schema_version":1,"captured_at":"\#(isoUTC(now.addingTimeInterval(30)))","rate_limits":{"five_hour":{"used_percentage":77}}}"#.utf8).write(to: hookWin)
        try Data(#"{"schema_version":1,"captured_at":"\#(isoUTC(now.addingTimeInterval(-10)))","rate_limits":{"five_hour":{"used_percentage":33}}}"#.utf8).write(to: probeOld)
        let win = ClaudeCodeAdapter.readStatuslineRateLimits(from: [hookWin, probeOld], now: now)
        XCTAssertEqual(win.first?.primary?.usedPercent, 77, "captured_at within tolerance must win")

        let hookScoped = dir.appendingPathComponent("hook-scoped.json")
        let probeScoped = dir.appendingPathComponent("probe-scoped.json")
        try Data(#"{"schema_version":1,"captured_at":"\#(future)","model_scoped":[{"display_name":"Fable","used_percentage":10,"observed_at":"\#(future)"}]}"#.utf8).write(to: hookScoped)
        try Data(#"{"schema_version":1,"captured_at":"\#(atNow)","model_scoped":[{"display_name":"Fable","used_percentage":42}]}"#.utf8).write(to: probeScoped)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: hookScoped.path)
        let scoped = ClaudeCodeAdapter.readModelScopedLimits(from: [hookScoped, probeScoped], now: now)
        XCTAssertEqual(scoped.first?.usedPercent, 42)

        // 時鐘超前時寫的檔:captured_at 與 mtime 來自同一個錯的時鐘,兩者都不可信。
        let skewed = now.addingTimeInterval(86400)
        try FileManager.default.setAttributes([.modificationDate: skewed], ofItemAtPath: hook.path)
        try FileManager.default.setAttributes([.modificationDate: skewed], ofItemAtPath: hookScoped.path)
        let skew = ClaudeCodeAdapter.readStatuslineRateLimits(from: [hook, probe], now: now)
        XCTAssertEqual(skew.first(where: { $0.primary != nil })?.primary?.usedPercent, 55, "future mtime must not win")
        XCTAssertEqual(skew.first(where: { $0.secondary != nil })?.secondary?.usedPercent, 60)
        let skewScoped = ClaudeCodeAdapter.readModelScopedLimits(from: [hookScoped, probeScoped], now: now)
        XCTAssertEqual(skewScoped.first?.usedPercent, 42, "future mtime must not win (scoped)")

        // hook 以 captured_at = now 重寫、沿用一個 observed_at 在未來的舊項目:該項不得借用新檔時間勝過探針。
        let hookCarry = dir.appendingPathComponent("hook-carry.json")
        let probeRecent = dir.appendingPathComponent("probe-recent.json")
        try Data(#"{"schema_version":1,"captured_at":"\#(atNow)","model_scoped":[{"display_name":"Fable","used_percentage":10,"observed_at":"\#(isoUTC(skewed))"}]}"#.utf8).write(to: hookCarry)
        try Data(#"{"schema_version":1,"captured_at":"\#(isoUTC(now.addingTimeInterval(-300)))","model_scoped":[{"display_name":"Fable","used_percentage":55}]}"#.utf8).write(to: probeRecent)
        let carried = ClaudeCodeAdapter.readModelScopedLimits(from: [hookCarry, probeRecent], now: now)
        XCTAssertEqual(carried.first?.usedPercent, 55, "item with untrusted observed_at must not borrow the file stamp")

        // 檔案時間不可信,但項目自帶可信 observed_at → 該項照收;沒自帶時間的項目丟棄。
        let skewFile = dir.appendingPathComponent("skew-file.json")
        let probeHourOld = dir.appendingPathComponent("probe-hour-old.json")
        try Data(#"{"schema_version":1,"captured_at":"\#(isoUTC(skewed))","model_scoped":[{"display_name":"Fable","used_percentage":55,"observed_at":"\#(atNow)"},{"display_name":"Other","used_percentage":7}]}"#.utf8).write(to: skewFile)
        try FileManager.default.setAttributes([.modificationDate: skewed], ofItemAtPath: skewFile.path)
        try Data(#"{"schema_version":1,"captured_at":"\#(isoUTC(now.addingTimeInterval(-3600)))","model_scoped":[{"display_name":"Fable","used_percentage":10}]}"#.utf8).write(to: probeHourOld)
        let kept = ClaudeCodeAdapter.readModelScopedLimits(from: [skewFile, probeHourOld], now: now)
        XCTAssertEqual(kept.first(where: { $0.displayName == "Fable" })?.usedPercent, 55, "item's own trusted observed_at survives an untrusted file stamp")
        XCTAssertNil(kept.first(where: { $0.displayName == "Other" }), "item without its own stamp in an untrusted file is dropped")

        // 邊界:captured_at 缺、mtime 恰為 now+60s → 可信;now+61s → 跳過。有效 captured_at + 未來 mtime → 照讀。
        let edge = dir.appendingPathComponent("edge.json")
        try Data(#"{"schema_version":1,"rate_limits":{"five_hour":{"used_percentage":12}}}"#.utf8).write(to: edge)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: edge.path)
        XCTAssertEqual(ClaudeCodeAdapter.readStatuslineRateLimits(from: [edge], now: now).first?.primary?.usedPercent, 12)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(61)], ofItemAtPath: edge.path)
        XCTAssertNil(ClaudeCodeAdapter.readStatuslineRateLimits(from: [edge], now: now).first?.primary)
        let validStamp = dir.appendingPathComponent("valid-stamp.json")
        try Data(#"{"schema_version":1,"captured_at":"\#(atNow)","rate_limits":{"five_hour":{"used_percentage":34}}}"#.utf8).write(to: validStamp)
        try FileManager.default.setAttributes([.modificationDate: skewed], ofItemAtPath: validStamp.path)
        XCTAssertEqual(ClaudeCodeAdapter.readStatuslineRateLimits(from: [validStamp], now: now).first?.primary?.usedPercent, 34)
    }

    func testCaptureAcceptsWideSpacedPercent() throws {
        let frame = "printf '\\033[2J\\033[HCurrent session\\r\\n5%%  used\\r\\n'"
        let bin = try fakeClaude("""
        trap '\(frame.replacingOccurrences(of: "'", with: "'\\''"))' WINCH
        \(frame)
        while true; do sleep 0.1; done
        """)
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 8)
        let p = screen.flatMap { ClaudeUsageProbe.parse(screen: $0, now: Date()) }
        XCTAssertNotNil(screen)
        XCTAssertEqual(p?.session?.usedPercent, 5)
    }

    /// 第一幀的 "5" 與 "% used" 分兩次 read 到達,中間夾 >256 bytes 的色碼:門檻仍須看見 "5% used"。
    func testCaptureGateSeesPercentSplitAcrossReads() throws {
        let clean = "printf '\\033[2J\\033[HCurrent session\\r\\n5%% used\\r\\n'"
        let bin = try fakeClaude("""
        trap '\(clean.replacingOccurrences(of: "'", with: "'\\''"))' WINCH
        printf '\\033[2J\\033[HCurrent session\\r\\n5'
        sleep 0.5
        i=0; while [ $i -lt 40 ]; do printf '\\033[38;2;10;20;30m'; i=$((i+1)); done
        printf '%% used\\r\\n'
        while true; do sleep 0.1; done
        """)
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 8)
        let p = screen.flatMap { ClaudeUsageProbe.parse(screen: $0, now: Date()) }
        XCTAssertNotNil(screen, "percent split across reads must still open the gate")
        XCTAssertEqual(p?.session?.usedPercent, 5)
    }

    func testCaptureGivesUpOnFloodingChild() throws {
        let bin = try fakeClaude("yes 'noise without numbers'")
        let t0 = Date()
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: makeTempDir(), timeout: 8)
        XCTAssertNil(screen)
        // 4 MiB 上限應遠早於 8s 逾時觸發(舊碼沒有上限,會一路收到逾時)。
        XCTAssertTrue(Date().timeIntervalSince(t0) < 6, "flood must hit the buffer cap, not the timeout: \(Date().timeIntervalSince(t0))")
    }

    /// cwd = home 會讓 Claude Code 掃 home → macOS 以本 app 名義跳 Documents/照片/其他 app 資料的權限提示。
    func testCaptureRunsInDedicatedEmptyDirectory() throws {
        let home = makeTempDir()
        let bin = try fakeClaude("""
        draw() { printf '\\033[2J\\033[HCurrent session\\r\\n5%% used\\r\\ncwd=%s\\r\\n' "$(pwd -P)"; }
        trap draw WINCH
        draw
        while true; do sleep 0.1; done
        """)
        let screen = ClaudeUsageProbe.captureScreen(binary: bin, home: home, timeout: 8)
        // realpath(3):Foundation 的 resolvingSymlinksInPath 會把 /private/var 剝回 /var,與 `pwd -P` 不同。
        let dir = home.appendingPathComponent("Library/Application Support/AIPetUsage/claude-probe").path
        let expected = realpath(dir, nil).map { p in defer { free(p) }; return String(cString: p) } ?? dir
        XCTAssertTrue(screen?.contains("cwd=\(expected)") == true, "probe must not run with cwd = home: \(screen ?? "nil")")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: expected), [], "work dir stays empty")
    }

    func testWriteLandingIsOwnerOnly() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent(ClaudeUsageProbe.landingFileName)
        let at = date("2026-11-16T02:00:00Z")
        guard let parsed = ClaudeUsageProbe.parse(screen: realScreen, now: at) else {
            XCTAssertNotNil(nil, "real screen must parse"); return
        }
        try ClaudeUsageProbe.writeLanding(parsed, capturedAt: at, to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        // 怪 umask(0400)也不可把擁有者讀權拿掉:adapter 要讀得回來。
        let strict = dir.appendingPathComponent("strict-umask.json")
        let old = umask(0o400)
        defer { umask(old) }
        try ClaudeUsageProbe.writeLanding(parsed, capturedAt: at, to: strict)
        umask(old)
        let strictMode = try FileManager.default.attributesOfItem(atPath: strict.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(strictMode?.intValue, 0o600, "umask must not strip owner read")
        let raw = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(obj?["source"] as? String, "usage-probe")
        XCTAssertEqual(obj?["captured_at"] as? String, isoUTC(at))
    }
}
