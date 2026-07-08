import Foundation
import UsageCore

// MARK: - 共用工具

func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        ?? Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
}

func makeTempDir(_ fn: StaticString = #function) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-tests-\(fn)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func date(_ iso: String) -> Date { ISO8601.parse(iso)! }

// MARK: - ISO8601 解析

final class ISO8601Tests: XCTestCase {
    func testParseVariants() {
        XCTAssertEqual(ISO8601.parse("2026-01-15T10:00:00Z")!.timeIntervalSince1970, 1768471200)
        XCTAssertEqual(ISO8601.parse("2026-01-15T10:00:00.500Z")!.timeIntervalSince1970, 1768471200.5, accuracy: 0.001)
        // +08:00 時區:同一瞬間應比 Z 早 8 小時的 UTC 值
        XCTAssertEqual(ISO8601.parse("2026-01-15T18:00:00+08:00")!.timeIntervalSince1970, 1768471200)
        XCTAssertNil(ISO8601.parse("not a date"))
        XCTAssertNil(ISO8601.parse("2026-01-15"))
    }
}

// MARK: - JSONL scanner

final class JSONLScannerTests: XCTestCase {
    func testChunkBoundaryScanPreservesOffsetsAndLines() throws {
        let chunkSize = 4 * 1024 * 1024
        let filter = "\"match\":\"scanner-regression\""

        func exactLine(label: String, totalLength: Int) -> Data {
            let prefix = "{\"match\":\"scanner-regression\",\"id\":\"\(label)\",\"payload\":\""
            let suffix = "\"}"
            let fixedLength = prefix.utf8.count + suffix.utf8.count
            precondition(totalLength >= fixedLength)
            return Data((prefix + String(repeating: "x", count: totalLength - fixedLength) + suffix).utf8)
        }

        var bytes = Data()
        var expectedOffsets: [Int64] = []
        var expectedLines: [Data] = []

        func appendLine(_ line: Data) {
            expectedOffsets.append(Int64(bytes.count))
            expectedLines.append(line)
            bytes.append(line)
            bytes.append(UInt8(0x0A))
        }

        let boundaryLineStart = chunkSize - 256
        let fixedLineLength = 640
        let minPaddingLineLength = 192
        var lineNumber = 0
        while bytes.count + fixedLineLength + 1 <= boundaryLineStart - (minPaddingLineLength + 1) {
            appendLine(exactLine(label: "pre-\(lineNumber)", totalLength: fixedLineLength))
            lineNumber += 1
        }

        let paddingLength = boundaryLineStart - bytes.count - 1
        XCTAssertGreaterThan(paddingLength, 0)
        appendLine(exactLine(label: "pad", totalLength: paddingLength))
        XCTAssertEqual(bytes.count, boundaryLineStart)

        let boundaryOffset = Int64(bytes.count)
        let boundaryLine = exactLine(label: "boundary", totalLength: 768)
        XCTAssertTrue(bytes.count < chunkSize)
        XCTAssertTrue(bytes.count + boundaryLine.count > chunkSize)
        appendLine(boundaryLine)

        for i in 0..<64 {
            appendLine(exactLine(label: "post-\(i)", totalLength: 256))
        }

        let finalExpectedOffset = Int64(bytes.count)
        bytes.append(exactLine(label: "partial", totalLength: 512))

        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("scanner.jsonl")
        try bytes.write(to: file)

        var hits: [JSONLScanner.LineHit] = []
        let finalOffset = try JSONLScanner.scan(url: file, from: 0, quickFilters: [filter]) { hit in
            hits.append(hit)
        }

        XCTAssertEqual(hits.map(\.byteOffset), expectedOffsets)
        let expectedByOffset = Dictionary(uniqueKeysWithValues: zip(expectedOffsets, expectedLines))
        let mismatchedOffsets = hits.compactMap { hit in
            expectedByOffset[hit.byteOffset] == hit.data ? nil : hit.byteOffset
        }
        XCTAssertTrue(mismatchedOffsets.isEmpty, "mismatched line bytes at offsets \(Array(mismatchedOffsets.prefix(5)))")
        let boundaryHit = hits.first { $0.byteOffset == boundaryOffset }
        XCTAssertTrue(boundaryHit != nil && boundaryHit!.data == boundaryLine, "boundary line was not reassembled intact")
        XCTAssertEqual(finalOffset, finalExpectedOffset)
    }
}

// MARK: - Trends 資料層(dailyBuckets / usageStreak)

final class TrendsDataTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func ev(_ id: String, _ provider: String, _ ts: String, _ tokens: Int) -> UsageEvent {
        UsageEvent(id: id, providerId: provider, timestamp: date(ts),
                   tokens: TokenBreakdown(input: tokens), sourceKind: "test")
    }

    func testDailyBucketsAggregateByLocalDay() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            ev("a", "codex", "2026-01-15T10:00:00Z", 100),
            ev("b", "claude-code", "2026-01-15T20:00:00Z", 50),
            ev("c", "codex", "2026-01-16T09:00:00Z", 30),
        ])
        let interval = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-17T00:00:00Z"))
        let buckets = ledger.dailyBuckets(in: interval, calendar: utc)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].day, date("2026-01-15T00:00:00Z"))
        XCTAssertEqual(buckets[0].tokens, 150)
        XCTAssertEqual(buckets[0].byProvider["codex"], 100)
        XCTAssertEqual(buckets[0].byProvider["claude-code"], 50)
        XCTAssertEqual(buckets[1].day, date("2026-01-16T00:00:00Z"))
        XCTAssertEqual(buckets[1].tokens, 30)
    }

    func testUsageStreakCurrentAndLongest() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            ev("x0", "codex", "2026-01-10T12:00:00Z", 10),   // 孤立日
            ev("x1", "codex", "2026-01-13T12:00:00Z", 10),
            ev("x2", "codex", "2026-01-14T12:00:00Z", 10),
            ev("x3", "codex", "2026-01-15T12:00:00Z", 10),
        ])
        // 今天 = 15(有用量):current 往回數 15,14,13 = 3;longest = 3
        let s1 = ledger.usageStreak(now: date("2026-01-15T20:00:00Z"), calendar: utc)
        XCTAssertEqual(s1.current, 3)
        XCTAssertEqual(s1.longest, 3)
        // 今天 = 16(空)但昨天 15 有 → current 仍為 3
        let s2 = ledger.usageStreak(now: date("2026-01-16T08:00:00Z"), calendar: utc)
        XCTAssertEqual(s2.current, 3)
        // 今天 = 17、昨天 16 都空 → current 0,longest 仍 3
        let s3 = ledger.usageStreak(now: date("2026-01-17T08:00:00Z"), calendar: utc)
        XCTAssertEqual(s3.current, 0)
        XCTAssertEqual(s3.longest, 3)
    }
}

// MARK: - Claude Code adapter

final class ClaudeCodeAdapterTests: XCTestCase {
    func makeRoot() throws -> URL {
        let root = makeTempDir()
        let projDir = root.appendingPathComponent("-Users-dev-projects-demo-app")
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("claude-session.jsonl"),
                                         to: projDir.appendingPathComponent("session-1.jsonl"))
        return root
    }

    func testParsesFixture() throws {
        let adapter = ClaudeCodeAdapter(roots: [try makeRoot()])
        let (result, state) = try adapter.refreshUsage(state: ScanState())

        // msg_001 重複兩次(串流重寫)只算一次;synthetic 略過;共 3 個有效事件。
        let ledger = UsageLedger(fileURL: nil)
        ledger.append(result.events)
        XCTAssertEqual(ledger.events.count, 3)

        let first = ledger.events.first { $0.id.contains("msg_001") }!
        XCTAssertEqual(first.tokens.input, 1200)
        XCTAssertEqual(first.tokens.output, 350)
        XCTAssertEqual(first.tokens.cacheRead, 8000)
        XCTAssertEqual(first.tokens.cacheWrite5m, 500)
        XCTAssertEqual(first.tokens.cacheWrite1h, 1500)
        XCTAssertEqual(first.modelId, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(first.projectName, "demo-app")
        XCTAssertEqual(first.projectId, "/Users/dev/projects/demo-app")

        // 無細分時 cache_creation_input_tokens 全數視為 5m
        let haiku = ledger.events.first { $0.modelId == "claude-haiku-4-5" }!
        XCTAssertEqual(haiku.tokens.cacheWrite5m, 400)
        XCTAssertEqual(haiku.tokens.cacheWrite1h, 0)

        // 掃描進度記錄了檔案位移
        XCTAssertEqual(state.files.count, 1)
        XCTAssertGreaterThan(state.files.values.first!.offset, 0)
    }

    func testStatuslinePayloadYieldsOfficialRateLimits() throws {
        // Claude Code statusline payload 的官方形狀(v2.1.x)
        let payload = """
        {"session_id":"s","model":{"id":"claude-fable-5","display_name":"Fable 5"},
         "rate_limits":{"five_hour":{"used_percentage":44,"resets_at":1783364400},
                        "seven_day":{"used_percentage":24,"resets_at":1783461600}}}
        """
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("claude-statusline.json")
        try payload.data(using: .utf8)!.write(to: file)

        let adapter = ClaudeCodeAdapter(roots: [makeTempDir()], statuslineFiles: [file])
        let (result, _) = try adapter.refreshUsage(state: ScanState())

        XCTAssertEqual(result.rateLimits.count, 1)
        let reading = result.rateLimits[0]
        XCTAssertEqual(reading.providerId, "claude-code")
        XCTAssertEqual(reading.primary?.usedPercent, 44)
        XCTAssertEqual(reading.primary?.windowMinutes, 300)
        XCTAssertEqual(reading.primary?.resetsAt?.timeIntervalSince1970, 1_783_364_400)
        XCTAssertEqual(reading.secondary?.usedPercent, 24)
        XCTAssertEqual(reading.secondary?.windowMinutes, 10080)

        // 檔案不存在 → 靜默略過,不產生讀值
        let empty = ClaudeCodeAdapter(roots: [makeTempDir()],
                                      statuslineFiles: [dir.appendingPathComponent("missing.json")])
        let (noResult, _) = try empty.refreshUsage(state: ScanState())
        XCTAssertTrue(noResult.rateLimits.isEmpty)
    }

    func testIncrementalScanDoesNotDuplicate() throws {
        let root = try makeRoot()
        let adapter = ClaudeCodeAdapter(roots: [root])
        let (r1, s1) = try adapter.refreshUsage(state: ScanState())
        let (r2, _) = try adapter.refreshUsage(state: s1)
        XCTAssertFalse(r1.events.isEmpty)
        XCTAssertTrue(r2.events.isEmpty, "沒有新內容時不應回傳事件")

        // 追加一行 → 只回傳新事件
        let file = root.appendingPathComponent("-Users-dev-projects-demo-app/session-1.jsonl")
        let newLine = """
        {"type":"assistant","cwd":"/Users/dev/projects/demo-app","sessionId":"s1","timestamp":"2026-01-15T12:00:00.000Z","uuid":"u9","requestId":"req_009","message":{"id":"msg_009","model":"claude-sonnet-4-5-20250929","role":"assistant","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}

        """
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: newLine.data(using: .utf8)!)
        try handle.close()

        let (r3, _) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertTrue(r3.events[0].id.contains("msg_009"))
    }

    func testDetectAvailabilityRechecksInjectedRootAfterCreation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aipet-tests-\(#function)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let adapter = ClaudeCodeAdapter(roots: [root])
        XCTAssertFalse(adapter.detectAvailability().available)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(adapter.detectAvailability().available)
    }
}

// MARK: - Codex adapter

final class CodexAdapterTests: XCTestCase {
    func makeRoot() throws -> URL {
        let root = makeTempDir()
        let dayDir = root.appendingPathComponent("2026/01/15")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL("codex-rollout.jsonl"),
                                         to: dayDir.appendingPathComponent("rollout-2026-01-15T09-00-00-abc123.jsonl"))
        return root
    }

    func testParsesTotalsDeltasAndRateLimits() throws {
        let adapter = CodexAdapter(roots: [try makeRoot()])
        let (result, _) = try adapter.refreshUsage(state: ScanState())

        // 三個 token_count:第一個建基準(事件=全量)、第二個差值、info:null 略過、第三個差值。
        XCTAssertEqual(result.events.count, 3)

        let e1 = result.events[0]
        // input 正規化為「非快取」:10000 - 6000
        XCTAssertEqual(e1.tokens.input, 4000)
        XCTAssertEqual(e1.tokens.cacheRead, 6000)
        XCTAssertEqual(e1.tokens.output, 800)
        XCTAssertEqual(e1.modelId, "gpt-5-codex")
        XCTAssertEqual(e1.projectName, "demo-app")

        let e2 = result.events[1]
        // 差值:in 15000-cached 12000=3000;output 1500
        XCTAssertEqual(e2.tokens.input, 3000)
        XCTAssertEqual(e2.tokens.cacheRead, 12000)
        XCTAssertEqual(e2.tokens.output, 1500)

        let e3 = result.events[2]
        XCTAssertEqual(e3.modelId, "gpt-5.1", "model 應追蹤最新 turn_context")
        XCTAssertEqual(e3.tokens.input + e3.tokens.cacheRead, 5000)

        // rate limits:4 筆讀值(含 info:null 那筆)
        XCTAssertEqual(result.rateLimits.count, 4)
        let r1 = result.rateLimits[0]
        XCTAssertEqual(r1.primary!.usedPercent, 10.0)
        XCTAssertEqual(r1.primary!.resetsAt!.timeIntervalSince1970, 1768475700)
        XCTAssertEqual(r1.secondary!.windowMinutes, 10080)
        XCTAssertEqual(r1.planType, "plus")
        // resets_in_seconds 後援:09:11:00Z + 3600
        let r4 = result.rateLimits[3]
        XCTAssertEqual(r4.primary!.resetsAt!.timeIntervalSince1970,
                       date("2026-01-15T09:11:00Z").timeIntervalSince1970 + 3600, accuracy: 1)
    }

    func testIncrementalPreservesContext() throws {
        let root = try makeRoot()
        let adapter = CodexAdapter(roots: [root])
        let (_, s1) = try adapter.refreshUsage(state: ScanState())

        // 追加新的 token_count(累計 36000/22000/3600)→ 差值必須以先前累計為基準
        let file = root.appendingPathComponent("2026/01/15/rollout-2026-01-15T09-00-00-abc123.jsonl")
        let newLine = """
        {"timestamp":"2026-01-15T09:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36000,"cached_input_tokens":22000,"output_tokens":3600,"reasoning_output_tokens":1000,"total_tokens":39600},"last_token_usage":{"input_tokens":6000,"cached_input_tokens":2000,"output_tokens":600,"reasoning_output_tokens":100,"total_tokens":6600}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":14.0,"window_minutes":300,"resets_at":1768475700},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1768914000},"plan_type":"plus"}}}

        """
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: newLine.data(using: .utf8)!)
        try handle.close()

        let (r2, _) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.count, 1)
        // 差值 = 36000-30000 - (22000-20000) = 4000 非快取
        XCTAssertEqual(r2.events[0].tokens.input, 4000)
        XCTAssertEqual(r2.events[0].tokens.cacheRead, 2000)
        XCTAssertEqual(r2.events[0].tokens.output, 600)
        XCTAssertEqual(r2.events[0].modelId, "gpt-5.1", "增量掃描必須保留 turn_context 上下文")
    }
}

// MARK: - Ledger

final class LedgerTests: XCTestCase {
    func event(_ id: String, _ ts: String, provider: String = "codex", tokens: Int = 100,
               project: String = "/p/alpha", model: String = "gpt-5-codex") -> UsageEvent {
        UsageEvent(id: id, providerId: provider, projectId: project,
                   projectName: URL(fileURLWithPath: project).lastPathComponent, modelId: model,
                   timestamp: date(ts), tokens: TokenBreakdown(input: tokens),
                   sourceKind: "test")
    }

    func testDedupeAndPersistence() {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        let l1 = UsageLedger(fileURL: file)
        XCTAssertEqual(l1.append([event("a", "2026-01-15T10:00:00Z"), event("a", "2026-01-15T10:00:00Z"),
                                  event("b", "2026-01-15T09:00:00Z")]), 2)
        XCTAssertEqual(l1.append([event("b", "2026-01-15T09:00:00Z")]), 0)
        XCTAssertEqual(l1.events.map(\.id), ["b", "a"], "應依時間排序")

        // 重新載入後仍去重、有序
        let l2 = UsageLedger(fileURL: file)
        XCTAssertEqual(l2.events.count, 2)
        XCTAssertEqual(l2.append([event("a", "2026-01-15T10:00:00Z")]), 0)
    }

    func testQueries() {
        let ledger = UsageLedger(fileURL: nil)
        ledger.append([
            event("a", "2026-01-15T10:00:00Z", tokens: 100, project: "/p/alpha"),
            event("b", "2026-01-15T11:00:00Z", tokens: 300, project: "/p/beta"),
            event("c", "2026-01-15T11:30:00Z", provider: "claude-code", tokens: 600, project: "/p/beta",
                  model: "claude-sonnet-4-5"),
            event("d", "2026-01-16T09:00:00Z", tokens: 1000),
        ])
        let day = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-16T00:00:00Z"))
        XCTAssertEqual(ledger.totals(in: day).total, 1000)
        XCTAssertEqual(ledger.totals(in: day, providerId: "claude-code").total, 600)

        let projects = ledger.projectSummaries(in: day, pricing: PricingRegistry(entries: []))
        XCTAssertEqual(projects.first!.projectName, "beta")
        XCTAssertEqual(projects.first!.tokens.total, 900)
        XCTAssertEqual(projects.first!.shareOfPeriod, 0.9, accuracy: 0.001)
        XCTAssertEqual(projects.first!.providers, ["claude-code", "codex"])

        // 燃燒率:以 11:45 為現在,前一小時內有 b+c = 900 tokens
        let burn = ledger.burnRatePerHour(window: 3600, now: date("2026-01-15T11:45:00Z"))
        XCTAssertEqual(burn, 900, accuracy: 0.1)
    }
}

// MARK: - LimitEngine

final class LimitEngineTests: XCTestCase {
    let settings = CoreSettings()

    func reading(_ percent: Double, at: String, resetsAt: String, weekly: Double = 50) -> RateLimitReading {
        RateLimitReading(
            providerId: "codex",
            observedAt: date(at),
            primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300, resetsAt: date(resetsAt)),
            secondary: RateLimitWindowReading(usedPercent: weekly, windowMinutes: 10080, resetsAt: date("2026-01-20T00:00:00Z"))
        )
    }

    func nilResetReading(_ percent: Double, at: String) -> RateLimitReading {
        RateLimitReading(
            providerId: "claude-code",
            observedAt: date(at),
            primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300, resetsAt: nil),
            secondary: nil
        )
    }

    func testUsedPercentCappedAtHundred() {
        let engine = LimitEngine(stateURL: nil)
        // 官方讀值或估算可能 >100;對外一律夾到 100(避免 UI 出現 103%)。
        _ = engine.ingest(readings: [
            RateLimitReading(providerId: "codex", observedAt: date("2026-01-15T10:00:00Z"),
                             primary: RateLimitWindowReading(usedPercent: 103, windowMinutes: 300,
                                                             resetsAt: date("2026-01-15T14:00:00Z")),
                             secondary: nil)
        ], settings: settings)
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 100)
    }

    func testMonotonicGuardWithinWindow() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(50, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 較舊面板回報較低值 → 不得下降
        _ = engine.ingest(readings: [reading(40, at: "2026-01-15T09:30:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        var state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 50)
        XCTAssertFalse(state.fiveHour.corrected)

        // 較新且較高 → 上升
        _ = engine.ingest(readings: [reading(60, at: "2026-01-15T10:10:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                  settings: settings, now: date("2026-01-15T10:15:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 60)

        // 較新但較低(同窗口)→ 仍維持最大值
        _ = engine.ingest(readings: [reading(55, at: "2026-01-15T10:20:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                  settings: settings, now: date("2026-01-15T10:25:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 60)
    }

    func testSameWindowZeroWindowMinutesDoesNotClobberStoredLength() {
        let engine = LimitEngine(stateURL: nil)
        let reset = date("2026-01-15T14:00:00Z")
        _ = engine.ingest(readings: [
            RateLimitReading(
                providerId: "codex",
                observedAt: date("2026-01-15T10:00:00Z"),
                primary: RateLimitWindowReading(usedPercent: 25, windowMinutes: 300, resetsAt: reset),
                secondary: nil
            )
        ], settings: settings)

        _ = engine.ingest(readings: [
            RateLimitReading(
                providerId: "codex",
                observedAt: date("2026-01-15T10:05:00Z"),
                primary: RateLimitWindowReading(usedPercent: 30, windowMinutes: 0,
                                                resetsAt: reset.addingTimeInterval(30)),
                secondary: nil
            )
        ], settings: settings)

        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:10:00Z"))
        XCTAssertEqual(state.fiveHour.windowMinutes, 300)
    }

    func testWindowRolloverAcceptsLowerAndEmitsReset() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let transitions = engine.ingest(readings: [reading(5, at: "2026-01-15T14:05:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(transitions.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T14:10:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 5)
    }

    func testNilResetRolloverAcceptsLowerAndEmitsReset() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [nilResetReading(45, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [nilResetReading(92, at: "2026-01-15T10:30:00Z")], settings: settings)
        let transitions = engine.ingest(readings: [nilResetReading(8, at: "2026-01-15T15:05:00Z")], settings: settings)
        XCTAssertTrue(transitions.contains(.reset(providerId: "claude-code", window: "5h")))
        let state = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T15:10:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 8)
    }

    func testHistoryDedupPreservesSlopeAcrossEqualRefreshes() {
        let engine = LimitEngine(stateURL: nil)
        let start = date("2026-01-15T10:00:00Z")
        let reset = date("2026-01-15T14:00:00Z")
        func sample(_ percent: Double, seconds: TimeInterval) -> RateLimitReading {
            RateLimitReading(
                providerId: "codex",
                observedAt: start.addingTimeInterval(seconds),
                primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300, resetsAt: reset),
                secondary: nil
            )
        }

        _ = engine.ingest(readings: [sample(10, seconds: 0)], settings: settings)
        _ = engine.ingest(readings: [sample(20, seconds: 900)], settings: settings)
        for i in 1...50 {
            _ = engine.ingest(readings: [sample(20, seconds: 900 + Double(i) * 10)], settings: settings)
        }
        _ = engine.ingest(readings: [sample(21, seconds: 1_420)], settings: settings)

        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: start.addingTimeInterval(1_430))
        XCTAssertNotNil(state.projectedExhaustionAt)
    }

    func testFullReindexAllowsDownwardCorrection() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(70, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [reading(55, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T14:00:00Z")],
                          settings: settings, fullReindex: true)
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:35:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 55)
        XCTAssertTrue(state.fiveHour.corrected, "重建索引後的向下修正必須標示")
    }

    func testThresholdCrossingsAndExhausted() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(70, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let t1 = engine.ingest(readings: [reading(85, at: "2026-01-15T10:10:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        XCTAssertTrue(t1.contains(.crossedThreshold(providerId: "codex", window: "5h", percent: 85, threshold: 80)))
        let t2 = engine.ingest(readings: [reading(100, at: "2026-01-15T10:20:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        XCTAssertTrue(t2.contains(.exhausted(providerId: "codex", window: "5h")))

        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:25:00Z"))
        XCTAssertEqual(state.warning, .exhausted)
    }

    func testExpiredWindowShowsRecoveredAndSweepEmitsReset() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(90, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 窗口過期後:顯示 0%(estimated),掃描發出一次 reset
        let now = date("2026-01-15T14:30:00Z")
        let t1 = engine.sweepExpiredWindows(now: now)
        XCTAssertTrue(t1.contains(.reset(providerId: "codex", window: "5h")))
        let t2 = engine.sweepExpiredWindows(now: now)
        XCTAssertTrue(t2.filter { if case .reset(_, "5h") = $0 { return true }; return false }.isEmpty,
                      "同一次過期只觸發一次 reset")

        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: now)
        XCTAssertEqual(state.fiveHour.usedPercent, 0)
        XCTAssertEqual(state.fiveHour.confidence, .estimated)
    }

    func testClaudeFiveHourBlocks() {
        func ev(_ ts: String, tokens: Int) -> UsageEvent {
            UsageEvent(id: UUID().uuidString, providerId: "claude-code", timestamp: date(ts),
                       tokens: TokenBreakdown(input: tokens), sourceKind: "test")
        }
        // 10:07 開第一個區塊(10:00–15:00);15:30 開第二個(15:00–20:00)
        let events = [ev("2026-01-15T10:07:00Z", tokens: 100),
                      ev("2026-01-15T12:00:00Z", tokens: 200),
                      ev("2026-01-15T15:30:00Z", tokens: 400)]

        let block = LimitEngine.fiveHourBlock(events: events, now: date("2026-01-15T16:00:00Z"))
        XCTAssertNotNil(block)
        XCTAssertEqual(block!.tokens, 400, "目前區塊只含 15:30 的事件")
        XCTAssertEqual(block!.end.timeIntervalSince(block!.start), 5 * 3600)
        XCTAssertTrue(block!.end > date("2026-01-15T16:00:00Z"))

        // 全部區塊都過期 → nil
        XCTAssertNil(LimitEngine.fiveHourBlock(events: events, now: date("2026-01-16T09:00:00Z")))
    }

    func testClaudeOfficialReadingsBeatBudgetEstimation() {
        // statusline 讀值存在時,Claude 應走 reading-backed 路徑(高信心),
        // 不再依賴使用者預算。
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T13:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 24, windowMinutes: 10080,
                                              resetsAt: date("2026-01-17T10:00:00Z"))
        )
        _ = engine.ingest(readings: [reading], settings: settings)
        let state = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 44)
        XCTAssertEqual(state.fiveHour.confidence, .high)
        XCTAssertEqual(state.weekly.usedPercent, 24)
        XCTAssertEqual(state.weekly.confidence, .high)
    }

    func testClaudeStaleReadingsFallBackToBudget() {
        // hook 停止更新後(讀值過期且觀測超過 24h),必須自動退回預算估算路徑。
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let engine = LimitEngine(stateURL: nil)
        let staleReading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-10T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-10T13:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 24, windowMinutes: 10080,
                                              resetsAt: date("2026-01-12T10:00:00Z"))
        )
        _ = engine.ingest(readings: [staleReading], settings: s)

        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code",
                                  timestamp: date("2026-01-15T10:07:00Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        // 5 天後:兩個窗口皆過期、觀測遠超 24h → 估算(80% of budget)
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-15T11:00:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent!, 80, accuracy: 0.01,
                       "過期讀值不得卡死預算後備")
        XCTAssertEqual(state.fiveHour.confidence, .estimated)

        // 新讀值一到,又回到官方路徑
        let fresh = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T11:30:00Z"),
            primary: RateLimitWindowReading(usedPercent: 12, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T15:00:00Z")),
            secondary: nil
        )
        _ = engine.ingest(readings: [fresh], settings: s)
        let back = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                     now: date("2026-01-15T11:35:00Z"))
        XCTAssertEqual(back.fiveHour.usedPercent, 12)
        XCTAssertEqual(back.fiveHour.confidence, .high)
    }

    func testClaudeExpiredReadingsWaitTwentyFourHoursBeforeBudgetFallback() {
        // 剛過期的官方讀值仍代表最近狀態;只有 24h 內都沒有新讀值時才交回預算後備。
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let engine = LimitEngine(stateURL: nil)
        let recentExpired = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T10:30:00Z")),
            secondary: nil
        )
        _ = engine.ingest(readings: [recentExpired], settings: s)

        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code",
                                  timestamp: date("2026-01-15T10:07:00Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-15T11:00:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 0)
        XCTAssertEqual(state.fiveHour.confidence, .estimated)
        XCTAssertNil(state.fiveHour.budgetTokens, "24h 內的過期官方讀值不得立刻啟用預算後備")
    }

    func testClaudeFiveHourFallsBackEvenWhenWeeklyReadingIsStillFutureDated() {
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T13:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 24, windowMinutes: 10080,
                                              resetsAt: date("2026-01-18T10:00:00Z"))
        )
        _ = engine.ingest(readings: [reading], settings: s)

        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code",
                                  timestamp: date("2026-01-16T11:07:00Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-16T12:00:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent!, 80, accuracy: 0.01,
                       "stale expired 5h reading must not stay at recovered 0% just because weekly reset is future-dated")
        XCTAssertEqual(state.fiveHour.budgetTokens, 1000)
        XCTAssertEqual(state.weekly.usedPercent, 24)
        XCTAssertEqual(state.weekly.confidence, .stale)
    }

    func testClaudeExpiredFiveHourFallsBackImmediatelyWhenLedgerShowsPostResetActivity() {
        // 5h 窗口 reset 後帳本已有新活動、官方檔卻停在 reset 前 → hook 已停,
        // 不得顯示 recovered 0% 撐滿 24h,應立即改用預算估算。
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let engine = LimitEngine(stateURL: nil)
        let preResetReading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T10:30:00Z")),
            secondary: nil
        )
        _ = engine.ingest(readings: [preResetReading], settings: s)

        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code",
                                  timestamp: date("2026-01-15T11:07:00Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        // reset(10:30)後 37 分鐘就有事件,但官方檔 mtime 停在 10:00 → 立即退回估算
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-15T12:00:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent!, 80, accuracy: 0.01,
                       "reset 後有帳本活動時,過期官方讀值不得以 recovered 0% 蓋掉預算估算")
        XCTAssertEqual(state.fiveHour.confidence, .estimated)
        XCTAssertEqual(state.fiveHour.budgetTokens, 1000)
        XCTAssertEqual(state.fiveHour.resetAt, date("2026-01-15T16:00:00Z"),
                       "估算路徑應給出 5h 區塊的預估 reset 時間")

        // hook 恢復寫入後,回到官方路徑
        let fresh = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T12:30:00Z"),
            primary: RateLimitWindowReading(usedPercent: 12, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T15:30:00Z")),
            secondary: nil
        )
        _ = engine.ingest(readings: [fresh], settings: s)
        let back = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                     now: date("2026-01-15T12:35:00Z"))
        XCTAssertEqual(back.fiveHour.usedPercent, 12)
        XCTAssertEqual(back.fiveHour.confidence, .high)
    }

    func testClaudeExpiredFiveHourToleratesScanRaceRightAfterReset() {
        // reset 邊界競態:活動只領先官方檔 30 秒(≤ 容差)→ 仍信任官方「已恢復」狀態,
        // 避免 hook 正常運作時在 reset 當下閃爍成估算值。
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let engine = LimitEngine(stateURL: nil)
        let reading = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T10:29:50Z"),
            primary: RateLimitWindowReading(usedPercent: 96, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T10:30:00Z")),
            secondary: nil
        )
        _ = engine.ingest(readings: [reading], settings: s)

        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code",
                                  timestamp: date("2026-01-15T10:30:20Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-15T10:31:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 0, "容差內的競態不應觸發估算後備")
        XCTAssertEqual(state.fiveHour.confidence, .estimated)
        XCTAssertNil(state.fiveHour.budgetTokens)
    }

    func testClaudeBudgetPercentAndEstimatedReset() {
        var s = settings
        s.claudeFiveHourTokenBudget = 1000
        let ledger = UsageLedger(fileURL: nil)
        ledger.append([UsageEvent(id: "e1", providerId: "claude-code", timestamp: date("2026-01-15T10:07:00Z"),
                                  tokens: TokenBreakdown(input: 800), sourceKind: "test")])
        let engine = LimitEngine(stateURL: nil)
        let state = engine.limitState(providerId: "claude-code", ledger: ledger, settings: s,
                                      now: date("2026-01-15T11:00:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent!, 80, accuracy: 0.01)
        XCTAssertEqual(state.fiveHour.confidence, .estimated)
        XCTAssertEqual(state.warning, .warning)

        // 區塊結束後,noteEstimatedBlock 應觸發 reset
        _ = engine.noteEstimatedBlock(providerId: "claude-code", blockEnd: date("2026-01-15T15:00:00Z"),
                                      blockTokens: 800, now: date("2026-01-15T11:00:00Z"))
        let t = engine.noteEstimatedBlock(providerId: "claude-code", blockEnd: nil, blockTokens: 0,
                                          now: date("2026-01-15T15:10:00Z"))
        XCTAssertTrue(t.contains(.reset(providerId: "claude-code", window: "5h")))
    }
}

// MARK: - Pricing

final class PricingTests: XCTestCase {
    func testMatchingAndCost() {
        let registry = PricingRegistry.loadDefault(overridesURL: nil)
        XCTAssertNotNil(registry.price(providerId: "claude-code", modelId: "claude-sonnet-4-5-20250929"),
                        "前綴樣式必須命中")
        XCTAssertNotNil(registry.price(providerId: "codex", modelId: "gpt-5"))
        XCTAssertNil(registry.price(providerId: "codex", modelId: "gpt-9-unknown"))
        XCTAssertNil(registry.price(providerId: "claude-code", modelId: nil))

        let event = UsageEvent(id: "e", providerId: "claude-code", modelId: "claude-sonnet-4-5-20250929",
                               timestamp: Date(),
                               tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000,
                                                      cacheRead: 1_000_000, cacheWrite5m: 1_000_000),
                               sourceKind: "test")
        let cost = registry.cost(of: event)
        // 3 + 15 + 0.3 + 3.75
        XCTAssertEqual(cost.knownUSD, 22.05, accuracy: 0.001)
        XCTAssertEqual(cost.unknownModelTokens, 0)
        XCTAssertFalse(cost.isEstimated)
    }

    func testUnknownModelIsNotSilentlyPriced() {
        let registry = PricingRegistry.loadDefault(overridesURL: nil)
        let event = UsageEvent(id: "e", providerId: "codex", modelId: "gpt-9-experimental", timestamp: Date(),
                               tokens: TokenBreakdown(input: 500, output: 500), sourceKind: "test")
        let cost = registry.cost(of: event)
        XCTAssertEqual(cost.knownUSD, 0)
        XCTAssertEqual(cost.unknownModelTokens, 1000)
        XCTAssertTrue(cost.isEstimated)
    }

    func testBundledPriceListCoversCurrentModels() {
        XCTAssertNotNil(PricingRegistry.bundledPrices(named: "model-prices"), "手動價目資源必須可載入")
        let generated = PricingRegistry.bundledPrices(named: "model-prices-generated")
        XCTAssertNotNil(generated, "OpenRouter 生成價目資源必須可載入")
        XCTAssertGreaterThan(generated!.count, 50, "完整價目應涵蓋長尾模型")
        for entry in generated! {
            XCTAssertGreaterThan(entry.inputPerMillion, 0)
            XCTAssertTrue(["claude-code", "codex", "antigravity", "grok-code"].contains(entry.providerId))
        }
        let registry = PricingRegistry.loadDefault(overridesURL: nil)

        // 生成長尾的例子:fast 變體有獨立(較長)前綴,不得吃到標準版價格
        if let fast = registry.price(providerId: "claude-code", modelId: "claude-opus-4-8-fast") {
            XCTAssertEqual(fast.inputPerMillion, 10, "fast 模式溢價必須來自較長前綴的條目")
        }

        // 使用者實際在用的模型必須有價(2026-07 驗證過的官方價)
        let opus48 = registry.price(providerId: "claude-code", modelId: "claude-opus-4-8")
        XCTAssertEqual(opus48?.inputPerMillion, 5)
        XCTAssertEqual(opus48?.outputPerMillion, 25)
        XCTAssertEqual(opus48?.cacheReadPerMillion, 0.5)
        XCTAssertEqual(opus48?.cacheWrite1hPerMillion, 10)

        let fable = registry.price(providerId: "claude-code", modelId: "claude-fable-5")
        XCTAssertEqual(fable?.inputPerMillion, 10)
        XCTAssertEqual(fable?.outputPerMillion, 50)

        let gpt55 = registry.price(providerId: "codex", modelId: "gpt-5.5")
        XCTAssertEqual(gpt55?.inputPerMillion, 5)
        XCTAssertEqual(gpt55?.outputPerMillion, 30)
        XCTAssertEqual(gpt55?.cacheReadPerMillion, 0.5)

        // gpt-5.5 是精確比對:不得誤吃 gpt-5.5-pro($30/$180)
        let pro = registry.price(providerId: "codex", modelId: "gpt-5.5-pro")
        XCTAssertEqual(pro?.inputPerMillion, 30)
        XCTAssertNil(registry.price(providerId: "codex", modelId: "gpt-5.5-nano-fake"),
                     "未收錄的變體不得誤配 gpt-5.5 精確項目")

        // 帳本中實際出現過的 gpt-5.4(2026-07-04)也必須有價
        let gpt54 = registry.price(providerId: "codex", modelId: "gpt-5.4")
        XCTAssertEqual(gpt54?.inputPerMillion, 2.5)
        XCTAssertEqual(gpt54?.outputPerMillion, 15)
        XCTAssertEqual(gpt54?.cacheReadPerMillion, 0.25)

        // 成本試算:opus-4-8 各 1M tokens = 5 + 25 + 0.5 + 6.25
        let event = UsageEvent(id: "e", providerId: "claude-code", modelId: "claude-opus-4-8",
                               timestamp: Date(),
                               tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000,
                                                      cacheRead: 1_000_000, cacheWrite5m: 1_000_000),
                               sourceKind: "test")
        XCTAssertEqual(registry.cost(of: event).knownUSD, 36.75, accuracy: 0.001)
    }

    func testUserOverrideBeatsBuiltin() {
        let dir = makeTempDir()
        let overridesURL = dir.appendingPathComponent("pricing-overrides.json")
        let override = ModelPrice(providerId: "codex", modelId: "gpt-5.5", displayName: "GPT-5.5",
                                  inputPerMillion: 2, outputPerMillion: 16, cacheReadPerMillion: 0.2,
                                  effectiveFrom: "2026-01-01", source: "user")
        try! AtomicJSON.write([override], to: overridesURL)
        let registry = PricingRegistry.loadDefault(overridesURL: overridesURL)
        let p = registry.price(providerId: "codex", modelId: "gpt-5.5")
        XCTAssertNotNil(p)
        XCTAssertTrue(p!.userOverride)
        XCTAssertEqual(p!.inputPerMillion, 2)
    }
}

// MARK: - 報告

final class ReportTests: XCTestCase {
    func testReportSectionsAndRedaction() {
        let period = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-15T23:00:00Z"))
        let project = ProjectSummary(
            projectId: "/Users/secret/path/demo-app", projectName: "demo-app<script>",
            tokens: TokenBreakdown(input: 1000), cost: CostResult(knownUSD: 1.5),
            providers: ["codex"], topModel: "gpt-5-codex", lastActive: date("2026-01-15T12:00:00Z"),
            shareOfPeriod: 1.0
        )
        let data = ReportData(
            title: "Daily Usage Report",
            period: period,
            generatedAt: date("2026-01-15T23:00:00Z"),
            timezoneName: "Asia/Taipei",
            totals: TokenBreakdown(input: 1000),
            cost: CostResult(knownUSD: 1.5, unknownModelTokens: 200, isEstimated: true),
            byProvider: [ProviderDaySummary(providerId: "codex", displayName: "Codex",
                                            tokens: TokenBreakdown(input: 1000), cost: CostResult(knownUSD: 1.5))],
            limitStates: [ProviderLimitState(providerId: "codex",
                                             fiveHour: LimitWindowState(usedPercent: 12, windowMinutes: 300, confidence: .high),
                                             weekly: LimitWindowState(usedPercent: 73, windowMinutes: 10080, confidence: .high))],
            projects: [project],
            models: [ModelUsageSummary(providerId: "codex", modelId: "gpt-5.5",
                                       tokens: TokenBreakdown(input: 200), cost: .zero)],
            buckets: [("01-15 10:00", 1000)],
            pricingRows: [],
            unknownModels: [("codex/gpt-5.5", 200)],
            dataQuality: ["codex: 1 unparsable line(s) skipped on last scan"],
            petSummary: "Mochi was calm today."
        )
        let html = ReportGenerator.generateHTML(data)

        for heading in ["Summary", "Usage by coding agent", "Limit status", "Projects",
                        "Timeline", "Model pricing assumptions", "Data quality", "Pet summary"] {
            XCTAssertTrue(html.contains("<h2>\(heading)</h2>"), "缺少段落:\(heading)")
        }
        XCTAssertTrue(html.contains("generated locally"), "缺少隱私聲明")
        XCTAssertFalse(html.contains("/Users/secret/path"), "預設不得輸出完整本機路徑")
        XCTAssertTrue(html.contains("demo-app&lt;script&gt;"), "HTML 必須跳脫")
        XCTAssertFalse(html.contains("demo-app<script>"))
        XCTAssertTrue(html.contains("unknown model"), "未知模型必須明示而非套錯價")
        XCTAssertTrue(html.contains("<style>"), "CSS 需內嵌以離線可讀")
        XCTAssertFalse(html.lowercased().contains("<script src"), "不得引用外部資源")
    }
}
