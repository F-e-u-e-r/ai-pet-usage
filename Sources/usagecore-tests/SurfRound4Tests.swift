import Foundation
@testable import UsageCore

/// Regressions from bug-surf round 4 (sol 6.1 + Gemini Argon findings, reproduced before fixing).
final class SurfRound4Tests: XCTestCase {
    private let now = date("2026-11-16T12:00:00Z")

    // MARK: - Cursor quota

    /// A malformed far-future billing end used to trap `Int(_:)` (crash) when sizing the window.
    func testCursorMonthlyWindowClampsAbsurdBillingEnd() {
        let body = #"{"billingCycleStart":"1000","billingCycleEnd":"1e30","planUsage":{"autoPercentUsed":5}}"#
        guard case .success(let snap) = CursorQuotaEngine.parseResponse(statusCode: 200, data: Data(body.utf8), now: now)
        else { return XCTAssertTrue(false, "expected success") }
        XCTAssertNil(snap.billingCycleEnd, "implausible date dropped at parse")
        XCTAssertEqual(snap.monthlyWindowMinutes, 43_200)
        // Every render path that formats the reset (menu row, dashboard) must not trap.
        _ = CursorQuotaDisplay.meterSummary(5, quota: snap, now: now)
        for st in CursorQuotaDisplay.syntheticLimitStates(from: snap, base: nil, now: now) {
            _ = ResetLabel.countdown(to: st.weekly.resetAt, now: now)
        }
        // A directly built snapshot with a far end still clamps rather than trapping.
        let direct = CursorQuotaSnapshot(autoPercentUsed: 1, apiPercentUsed: 1, billingCycleStart: Date(timeIntervalSince1970: 1),
                                         billingCycleEnd: Date(timeIntervalSince1970: 1e20), fetchedAt: now)
        XCTAssertEqual(direct.monthlyWindowMinutes, 62_400)
        // A real-looking date still parses.
        let ok = #"{"billingCycleStart":"1793886977012","billingCycleEnd":"1796478977012","planUsage":{"autoPercentUsed":5}}"#
        if case .success(let s2) = CursorQuotaEngine.parseResponse(statusCode: 200, data: Data(ok.utf8), now: now) {
            XCTAssertNotNil(s2.billingCycleEnd)
        } else { XCTAssertTrue(false, "expected success") }
    }

    private func cursorRows(fetchedAt: Date, cycleEnd: Date?) -> [ProviderLimitState] {
        let base = ProviderLimitState(providerId: "cursor-ide",
                                      fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
                                      weekly: LimitWindowState(windowMinutes: 10_080, confidence: .unknown),
                                      burnRateTokensPerHour: 0, lastEventAt: nil, lastReadingAt: nil, warning: .ok)
        let quota = CursorQuotaSnapshot(autoPercentUsed: 90, apiPercentUsed: 40,
                                        billingCycleStart: now.addingTimeInterval(-20 * 86_400),
                                        billingCycleEnd: cycleEnd, fetchedAt: fetchedAt)
        return CursorQuotaDisplay.expandLimitStates([base], quota: quota, now: now)
    }

    func testCursorFreshQuotaIsLive() {
        let rows = cursorRows(fetchedAt: now.addingTimeInterval(-60), cycleEnd: now.addingTimeInterval(86_400))
        XCTAssertEqual(rows.map(\.warning), [.ok, .ok])
        XCTAssertEqual(rows.first?.weekly.usedPercent, 90)
        XCTAssertNil(rows.first.flatMap { StatuslineAge.weeklyAsOfLabel(for: $0, now: now) })
    }

    /// Fetch failing for hours: the kept snapshot is flagged stale and labelled with its age.
    func testCursorOldQuotaMarkedStaleAndLabelled() {
        let rows = cursorRows(fetchedAt: now.addingTimeInterval(-3 * 3600), cycleEnd: now.addingTimeInterval(86_400))
        XCTAssertEqual(rows.map(\.warning), [.stale, .stale])
        XCTAssertEqual(rows.first?.weekly.usedPercent, 90, "value kept, only flagged")
        XCTAssertEqual(rows.first.flatMap { StatuslineAge.weeklyAsOfLabel(for: $0, now: now) }, "as of 3h ago")
    }

    /// Offline past the billing cycle end: the old month's percentage is not shown as current.
    func testCursorQuotaPastBillingEndDropsValue() {
        let rows = cursorRows(fetchedAt: now.addingTimeInterval(-2 * 86_400), cycleEnd: now)
        XCTAssertEqual(rows.map { $0.weekly.usedPercent == nil }, [true, true])
        XCTAssertEqual(rows.map(\.weeklyOfficial), [.expiredUnusable, .expiredUnusable])
    }

    // MARK: - Cursor IDE log counters

    /// Absurd counters in a log line used to overflow `TokenBreakdown.total` and trap.
    func testCursorTokenCountersAreCapped() {
        let cur = TokenBreakdown(input: CursorIdeAdapter.parseInt("9223372036854775807"),
                                 output: CursorIdeAdapter.parseInt("1"),
                                 cacheRead: CursorIdeAdapter.parseInt("9223372036854775807"),
                                 cacheWriteUnknown: CursorIdeAdapter.parseInt("-5"))
        XCTAssertEqual(cur.input, CursorIdeAdapter.maxTokenCount)
        XCTAssertEqual(cur.cacheWriteUnknown, 0)
        XCTAssertEqual(cur.total, 2 * CursorIdeAdapter.maxTokenCount + 1)
        XCTAssertEqual(CursorIdeAdapter.parseInt("1234"), 1234)
    }

    // MARK: - agy /usage subprocess

    /// Output past the pipe buffer used to block the child until the 20 s timeout → nil.
    func testAgyFetchReadsOutputLargerThanPipeBuffer() throws {
        let dir = makeTempDir()
        let padding = String(repeating: " ", count: 300_000)
        let json = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"g5","name":"5h","window":"5h","remaining_fraction":0.75}]}]}}}"# + padding
        let payload = dir.appendingPathComponent("usage.json")
        try json.write(to: payload, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("agy")
        try "#!/bin/sh\ncat '\(payload.path)'\necho noise >&2\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        let snap = AntigravityQuotaFetcher.fetch(now: now, executableURL: script)
        XCTAssertEqual(snap?.groups.first?.buckets.first?.usedPercent ?? -1, 25, accuracy: 0.01)
        XCTAssertTrue(Date().timeIntervalSince(started) < 10, "must not wait for the timeout")
    }

    /// A descendant that inherits stdout and outlives `agy` must not stall the fetch (or pin a blocked thread).
    func testAgyFetchNotStalledByDescendantHoldingStdout() throws {
        let dir = makeTempDir()
        let json = #"{"command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"g5","name":"5h","window":"5h","remaining_fraction":0.5}]}]}}}"#
        let script = dir.appendingPathComponent("agy")
        try "#!/bin/sh\nprintf '%s' '\(json)'\nsleep 30 &\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let started = Date()
        let snap = AntigravityQuotaFetcher.fetch(now: now, executableURL: script)
        XCTAssertEqual(snap?.groups.first?.buckets.first?.usedPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertTrue(Date().timeIntervalSince(started) < 10, "must not wait for the descendant or the timeout")
    }

    /// Dashboard Cursor panel renders the raw snapshot; a past billing cycle must not show its old %.
    func testCursorDashboardSummaryDropsExpiredValue() {
        let live = CursorQuotaSnapshot(autoPercentUsed: 90, apiPercentUsed: 40, billingCycleStart: nil,
                                       billingCycleEnd: now.addingTimeInterval(3600), fetchedAt: now)
        XCTAssertTrue(CursorQuotaDisplay.meterSummary(90, quota: live, now: now).hasPrefix("90% used · resets "))
        let ended = CursorQuotaSnapshot(autoPercentUsed: 90, apiPercentUsed: 40, billingCycleStart: nil,
                                        billingCycleEnd: now, fetchedAt: now.addingTimeInterval(-86_400))
        XCTAssertEqual(CursorQuotaDisplay.meterSummary(90, quota: ended, now: now), "— · awaiting Cursor refresh")
    }

    /// A full reindex fetches a fresh quota; it used to be discarded, leaving the old one on screen.
    func testFullReindexPersistsFreshAntigravityQuota() {
        let dir = makeTempDir()
        let old = AntigravityQuotaSnapshot(fetchedAt: now.addingTimeInterval(-86_400), groups: [
            AntigravityQuotaGroup(name: "Gemini Models", buckets: [
                AntigravityQuotaBucket(id: "g5", label: "5h", windowMinutes: 300, usedPercent: 20,
                                       remainingPercent: 80, resetsAt: nil)])])
        AntigravityQuotaStore.save(old, dataDir: dir)
        var fresh = old
        fresh.fetchedAt = now
        fresh.groups[0].buckets[0].usedPercent = 80
        let brain = dir.appendingPathComponent("brain", isDirectory: true)   // available → rescanned
        try? FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        let adapter = AgyAdapter(brainRoots: [brain], conversationMetadataURLs: [],
                                 enableOfficialQuotaFetch: true, quotaFetcher: { fresh })
        let coord = UsageCoordinator(dataDir: dir, settings: CoreSettings(enabledProviders: ["antigravity"]),
                                     adapters: [adapter])
        let sem = DispatchSemaphore(value: 0)
        Task { _ = await coord.refresh(fullReindex: true); sem.signal() }
        sem.wait()
        XCTAssertEqual(AntigravityQuotaStore.load(dataDir: dir)?.groups.first?.buckets.first?.usedPercent, 80)
    }

    // MARK: - Widget

    /// Host app quit before midnight: yesterday's totals must not render as "today".
    func testWidgetSnapshotDayCheck() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let snap = WidgetSnapshot(generatedAt: date("2026-11-15T23:50:00Z"), todayTokens: 10_000,
                                  todayCostUSD: 1, todayCostIsEstimated: false, rows: [])
        XCTAssertTrue(snap.isFromSameDay(as: date("2026-11-15T23:59:00Z"), calendar: cal))
        XCTAssertFalse(snap.isFromSameDay(as: date("2026-11-16T00:01:00Z"), calendar: cal))
    }
}
