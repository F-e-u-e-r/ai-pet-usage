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
    }
}
