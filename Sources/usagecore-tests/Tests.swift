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

    func testDailyBucketsTopProjectModelAndCost() {
        let ledger = UsageLedger(fileURL: nil)
        _ = ledger.append([
            UsageEvent(id: "d1", providerId: "codex", projectName: "big-app", modelId: "gpt-5.5",
                       timestamp: date("2026-01-15T10:00:00Z"), tokens: TokenBreakdown(input: 1000), sourceKind: "test"),
            UsageEvent(id: "d2", providerId: "codex", projectName: "small", modelId: "gpt-5.5",
                       timestamp: date("2026-01-15T11:00:00Z"), tokens: TokenBreakdown(input: 100), sourceKind: "test"),
        ])
        let interval = DateInterval(start: date("2026-01-15T00:00:00Z"), end: date("2026-01-16T00:00:00Z"))
        let pricing = PricingRegistry(entries: [
            ModelPrice(providerId: "codex", modelId: "gpt-5.5", displayName: "GPT-5.5",
                       inputPerMillion: 5, outputPerMillion: 30, effectiveFrom: "2026-01-01", source: "test")
        ])
        let buckets = ledger.dailyBuckets(in: interval, calendar: utc, pricing: pricing)
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].topProject, "big-app")   // 1000 > 100 tokens
        XCTAssertEqual(buckets[0].topModel, "gpt-5.5")
        XCTAssertGreaterThan(buckets[0].cost.knownUSD, 0)  // 1100 input @ $5/M ≈ $0.0055
        XCTAssertEqual(buckets[0].cost.unknownModelTokens, 0)   // 有定價 → 無未定價 tokens
        // 空 pricing(model 未定價)→ knownUSD 0 但 unknownModelTokens 反映用量(不看起來像零花費)
        let unpriced = ledger.dailyBuckets(in: interval, calendar: utc, pricing: PricingRegistry(entries: []))
        XCTAssertEqual(unpriced[0].cost.knownUSD, 0)
        XCTAssertGreaterThan(unpriced[0].cost.unknownModelTokens, 0)
        // 不傳 pricing → cost .zero,但 top project/model 仍算
        let noPrice = ledger.dailyBuckets(in: interval, calendar: utc)
        XCTAssertEqual(noPrice[0].cost.knownUSD, 0)
        XCTAssertEqual(noPrice[0].topProject, "big-app")
    }
}

// MARK: - 排程匯出 plist

final class ScheduledReportTests: XCTestCase {
    func testPlistXMLContentAndEscaping() {
        let spec = ScheduledReportSpec(
            label: "dev.aipetusage.app.report",
            programPath: "/Apps/AI Pet Usage.app/Contents/MacOS/aipet",
            days: 0, outDir: "/Users/x/Reports & Logs",
            hour: 99, minute: 5, homePath: "/Users/x",
            stdoutLog: "/tmp/o.log", stderrLog: "/tmp/e.log",
            extraEnv: ["CODEX_HOME": "/Users/x/.codex"])
        XCTAssertEqual(spec.days, 1)     // clamp
        XCTAssertEqual(spec.hour, 23)    // clamp
        let xml = spec.plistXML()
        XCTAssertTrue(xml.contains("<key>Label</key><string>dev.aipetusage.app.report</string>"))
        XCTAssertTrue(xml.contains("<string>--out-dir</string><string>/Users/x/Reports &amp; Logs</string>"))
        XCTAssertTrue(xml.contains("<string>--refresh</string>"))
        XCTAssertTrue(xml.contains("<key>Hour</key><integer>23</integer><key>Minute</key><integer>5</integer>"))
        XCTAssertTrue(xml.contains("<key>CODEX_HOME</key><string>/Users/x/.codex</string>"))
        XCTAssertFalse(xml.contains("& Logs"), "未 escape 的 & 不應出現")
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
        let adapter = ClaudeCodeAdapter(roots: [try makeRoot()], statuslineFiles: [], planConfigFiles: [])
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

        // planConfigFiles: [] — 隔離本機 ~/.claude.json,rateLimits 只含 statusline 讀數
        let adapter = ClaudeCodeAdapter(roots: [makeTempDir()], statuslineFiles: [file], planConfigFiles: [])
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
                                      statuslineFiles: [dir.appendingPathComponent("missing.json")],
                                      planConfigFiles: [])
        let (noResult, _) = try empty.refreshUsage(state: ScanState())
        XCTAssertTrue(noResult.rateLimits.isEmpty)
    }

    func testIncrementalScanDoesNotDuplicate() throws {
        let root = try makeRoot()
        let adapter = ClaudeCodeAdapter(roots: [root], statuslineFiles: [], planConfigFiles: [])
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

        let adapter = ClaudeCodeAdapter(roots: [root], statuslineFiles: [], planConfigFiles: [])
        XCTAssertFalse(adapter.detectAvailability().available)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(adapter.detectAvailability().available)
    }

    // MARK: statusline per-window 最新讀數合成(每窗獨立 observedAt;交叉污染防護)

    func testStatuslinePerWindowFreshestComposition() throws {
        let dir = makeTempDir()
        let oldFile = dir.appendingPathComponent("old.json")   // 兩窗齊全,但檔案舊
        let newFile = dir.appendingPathComponent("new.json")   // 只有 5h,檔案新
        try """
        {"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1783364400},
                        "seven_day":{"used_percentage":25,"resets_at":1783461600}}}
        """.data(using: .utf8)!.write(to: oldFile)
        try """
        {"rate_limits":{"five_hour":{"used_percentage":59,"resets_at":1783364400}}}
        """.data(using: .utf8)!.write(to: newFile)
        let oldMtime = date("2026-01-10T00:00:00Z")
        let newMtime = date("2026-01-15T10:00:00Z")
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: newMtime], ofItemAtPath: newFile.path)

        let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [oldFile, newFile])
        XCTAssertEqual(readings.count, 2, "兩窗來自不同檔 → 拆成兩筆")

        let primaryOnly = readings.first { $0.primary != nil }!
        XCTAssertNil(primaryOnly.secondary)
        XCTAssertEqual(primaryOnly.primary?.usedPercent, 59, "5h 取新檔")
        XCTAssertEqual(primaryOnly.observedAt, newMtime)

        let secondaryOnly = readings.first { $0.secondary != nil }!
        XCTAssertNil(secondaryOnly.primary)
        XCTAssertEqual(secondaryOnly.secondary?.usedPercent, 25, "weekly 只有舊檔有 → 保留")
        XCTAssertEqual(secondaryOnly.observedAt, oldMtime,
                       "weekly 必須帶自己來源檔的 mtime,不得借用活躍檔的新鮮度")

        // 新檔再度更新 → weekly 讀數的 observedAt 仍不得前進(交叉污染防護)。
        try FileManager.default.setAttributes([.modificationDate: date("2026-01-15T10:30:00Z")],
                                              ofItemAtPath: newFile.path)
        let again = ClaudeCodeAdapter.readStatuslineRateLimits(from: [oldFile, newFile])
        let weeklyAgain = again.first { $0.secondary != nil }!
        XCTAssertEqual(weeklyAgain.observedAt, oldMtime)

        // 兩窗同檔 → 合為一筆(observedAt 相同,無污染疑慮)。
        let single = ClaudeCodeAdapter.readStatuslineRateLimits(from: [oldFile])
        XCTAssertEqual(single.count, 1)
        XCTAssertNotNil(single[0].primary)
        XCTAssertNotNil(single[0].secondary)
    }

    // MARK: 訂閱方案標籤(窄解碼 + 映射優先序)

    // 端到端:adapter 拆筆 → engine 連餵兩輪。活躍 5h 檔連續更新時,舊檔的
    // 較低 weekly 值不得被灌新鮮 observedAt 而湊成二筆確認(R2-P1-1 的完整鏈路釘)。
    func testStatuslineSplitReadingsEndToEndNoCrossPollution() throws {
        let dir = makeTempDir()
        let oldFile = dir.appendingPathComponent("old.json")
        let newFile = dir.appendingPathComponent("new.json")
        try """
        {"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":1783364400},
                        "seven_day":{"used_percentage":45,"resets_at":1783461600}}}
        """.data(using: .utf8)!.write(to: oldFile)
        try """
        {"rate_limits":{"five_hour":{"used_percentage":59,"resets_at":1783364400}}}
        """.data(using: .utf8)!.write(to: newFile)
        try FileManager.default.setAttributes([.modificationDate: date("2026-01-10T00:00:00Z")],
                                              ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: date("2026-01-15T10:00:00Z")],
                                              ofItemAtPath: newFile.path)

        let engine = LimitEngine(stateURL: nil)
        let settings = CoreSettings()
        // 先前的正式讀數:weekly 50(同窗;resets_at 同 oldFile 的 1783461600)。
        _ = engine.ingest(readings: [
            RateLimitReading(providerId: "claude-code", observedAt: date("2026-01-12T00:00:00Z"),
                             primary: nil,
                             secondary: RateLimitWindowReading(usedPercent: 50, windowMinutes: 10080,
                                                               resetsAt: Date(timeIntervalSince1970: 1_783_461_600)))
        ], settings: settings)

        // 兩輪:活躍 5h 檔 mtime 前進,舊檔 weekly 45 固定 → weekly 不得下修、不得 corrected。
        for touch in ["2026-01-15T10:00:00Z", "2026-01-15T10:30:00Z"] {
            try FileManager.default.setAttributes([.modificationDate: date(touch)],
                                                  ofItemAtPath: newFile.path)
            let readings = ClaudeCodeAdapter.readStatuslineRateLimits(from: [oldFile, newFile])
            _ = engine.ingest(readings: readings, settings: settings)
        }
        let ledger = UsageLedger(fileURL: nil)
        let s = engine.limitState(providerId: "claude-code", ledger: ledger,
                                  settings: settings, now: date("2026-01-15T10:35:00Z"))
        XCTAssertEqual(s.weekly.usedPercent, 50, "舊檔的較低 weekly 不得借新檔 mtime 湊二筆確認")
        XCTAssertFalse(s.weekly.corrected)
        XCTAssertEqual(s.fiveHour.usedPercent, 59, "5h 正常取新檔")
    }

    func testPlanLabelMappingPriority() {
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: "default_claude_max_20x", organizationType: "claude_max"), "Max 20x")
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: "default_claude_max_5x", organizationType: nil), "Max 5x")
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: "default_claude_pro", organizationType: nil), "Pro")
        // 未知 tier → 去前綴 title-case 兜底
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: "default_claude_max_42x", organizationType: nil), "Max 42x")
        // tier 缺 → organizationType
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: nil, organizationType: "claude_max"), "Max")
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: "", organizationType: "team"), "Team")
        XCTAssertEqual(ClaudeCodeAdapter.planLabel(tier: nil, organizationType: "enterprise"), "Enterprise")
        XCTAssertNil(ClaudeCodeAdapter.planLabel(tier: nil, organizationType: nil))
        XCTAssertNil(ClaudeCodeAdapter.planLabel(tier: nil, organizationType: "unknown_type"))
    }

    func testPlanOnlyReadingEmittedFromConfigFixture() throws {
        let dir = makeTempDir()
        let cfg = dir.appendingPathComponent("claude.json")
        // 僅含所需鍵的最小 fixture;真實檔案還有大量其他欄位(窄解碼必須容忍並忽略)。
        try """
        {"numStartups":42,"oauthAccount":{"emailAddress":"x@example.com",
         "organizationRateLimitTier":"default_claude_max_20x","organizationType":"claude_max"},
         "projects":{"/tmp/x":{"history":["should-never-be-parsed"]}}}
        """.data(using: .utf8)!.write(to: cfg)

        let adapter = ClaudeCodeAdapter(roots: [makeTempDir()], statuslineFiles: [], planConfigFiles: [cfg])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.rateLimits.count, 1)
        XCTAssertEqual(result.rateLimits[0].planType, "Max 20x")
        XCTAssertNil(result.rateLimits[0].primary)
        XCTAssertNil(result.rateLimits[0].secondary)

        // 設定檔缺失 → 無 plan-only 讀數(絕不猜值)。
        let none = ClaudeCodeAdapter(roots: [makeTempDir()], statuslineFiles: [],
                                     planConfigFiles: [dir.appendingPathComponent("missing.json")])
        let (empty, _) = try none.refreshUsage(state: ScanState())
        XCTAssertTrue(empty.rateLimits.isEmpty)
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

    /// 迴歸(Part C):Codex 的 rate_limits primary/secondary 欄位「不」固定對應 5h/週;
    /// 以 window_minutes 分類(300→5h、10080→週),而非 JSON 位置。含 Codex 暫撤 5h、
    /// 只回報週窗口且放在 primary 的實況(週資料絕不可落入 5h 槽,plan 標籤須保留)。
    func testCodexClassifiesWindowsByDurationThroughRefresh() throws {
        let root = makeTempDir()
        let dayDir = root.appendingPathComponent("2026/07/12")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-07-12T17:50:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":54.0,"window_minutes":300,"resets_at":1783881382},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1784354760},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-07-12T18:40:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":43.0,"window_minutes":10080,"resets_at":1784354760},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-07-12T18:50:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":43.0,"window_minutes":10080,"resets_at":1784354760},"secondary":{"used_percent":55.0,"window_minutes":300,"resets_at":1783881382},"plan_type":"plus"}}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: dayDir.appendingPathComponent("rollout-2026-07-12T17-50-00-classify.jsonl"),
                        atomically: true, encoding: .utf8)
        let adapter = CodexAdapter(roots: [root])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.rateLimits.count, 3)
        // 正常:5h(300)→ primary、週(10080)→ secondary
        XCTAssertEqual(result.rateLimits[0].primary?.windowMinutes, 300)
        XCTAssertEqual(result.rateLimits[0].secondary?.windowMinutes, 10080)
        // 週窗口被放進 primary、無 secondary:必歸週槽,5h 槽為 nil(凍結,不污染),plan 保留
        XCTAssertNil(result.rateLimits[1].primary, "週窗口(10080)不得落入 5h 槽")
        XCTAssertEqual(result.rateLimits[1].secondary?.windowMinutes, 10080)
        XCTAssertEqual(result.rateLimits[1].planType, "plus")
        // 反序:仍以 window_minutes 正確歸位
        XCTAssertEqual(result.rateLimits[2].primary?.windowMinutes, 300)
        XCTAssertEqual(result.rateLimits[2].secondary?.windowMinutes, 10080)
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

    /// 迴歸(Part C sanitizer):載入時清掉「窗型錯置」的持久化窗口(週資料被寫進 5h 槽),
    /// 讓 Codex 暫撤 5h 時 UI 立即「凍結」(5h 無資料 → 無環);正確的週槽保留;且 init
    /// 期間不得寫檔(維持 aipet status/report 唯讀契約)。
    func testLoadSanitizesCrossTypedCodexWindows() throws {
        let stateURL = makeTempDir().appendingPathComponent("limits-state.json")
        // 模擬舊 adapter 錯置:把「週」形狀窗口(wm=10080)寫進 primary(5h)槽。
        let e1 = LimitEngine(stateURL: stateURL)
        _ = e1.ingest(readings: [RateLimitReading(
            providerId: "codex", observedAt: date("2026-07-12T18:40:00Z"),
            primary: RateLimitWindowReading(usedPercent: 46, windowMinutes: 10080,
                                            resetsAt: date("2026-07-18T06:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 42, windowMinutes: 10080,
                                              resetsAt: date("2026-07-18T06:00:00Z")))],
            settings: settings)
        let before = try Data(contentsOf: stateURL)
        // 重新載入 → init sanitizer 應在記憶體清掉錯置到 5h 槽的週資料。
        let e2 = LimitEngine(stateURL: stateURL)
        let s = e2.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                              settings: settings, now: date("2026-07-12T18:45:00Z"))
        XCTAssertNil(s.fiveHour.usedPercent, "錯置到 5h 槽的週資料須被清掉(凍結:無 5h → 無環)")
        XCTAssertEqual(s.weekly.usedPercent, 42, "正確的週槽須保留")
        let after = try Data(contentsOf: stateURL)
        XCTAssertEqual(before, after, "init 期間不得寫檔(維持 CLI 唯讀)")

        // exact/fail-closed:非 300 的短窗(如未來 60 分窗)落在 5h 槽也須被清,不得誤標「5h」。
        let url2 = makeTempDir().appendingPathComponent("limits-state.json")
        let f1 = LimitEngine(stateURL: url2)
        _ = f1.ingest(readings: [RateLimitReading(
            providerId: "codex", observedAt: date("2026-07-12T18:40:00Z"),
            primary: RateLimitWindowReading(usedPercent: 20, windowMinutes: 60,
                                            resetsAt: date("2026-07-12T19:40:00Z")),
            secondary: nil)], settings: settings)
        let s60 = LimitEngine(stateURL: url2).limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                                         settings: settings, now: date("2026-07-12T18:45:00Z"))
        XCTAssertNil(s60.fiveHour.usedPercent, "非 300 的短窗(exact/fail-closed)也須被清")

        // 遷移後封存重放:sanitizer 清掉錯置 5h(週資料,observedAt=18:40)時須一併記錄消失時點,
        // 使後續被重掃重放的舊 5h(observedAt ≤ 該時點)不得復活已凍結的 5h 槽。
        _ = e2.ingest(readings: [RateLimitReading(providerId: "codex", observedAt: date("2026-07-12T18:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 51, windowMinutes: 300, resetsAt: date("2026-07-12T23:00:00Z")),
            secondary: nil)], settings: settings)
        XCTAssertNil(e2.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                   settings: settings, now: date("2026-07-12T18:45:00Z")).fiveHour.usedPercent,
                     "遷移(sanitizer)清 5h 後,封存重放的舊 5h(≤消失時點)不得復活")
    }

    /// 迴歸(Part C tombstone):adapter→engine。正常快照(有 5h)後接週-only 快照(Codex 暫撤 5h),
    /// 5h 槽須被清(不 ghost 舊值,連 reindex 也保持凍結),週槽保留。反向的 primary-only 由
    /// testPrimaryOnlyReadingsDoNotDisturbStaleWeekly 守住(不 tombstone 週槽)。
    func testCodexWeeklyOnlySnapshotTombstonesFiveHour() throws {
        let root = makeTempDir()
        let dayDir = root.appendingPathComponent("2026/07/12")
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-07-12T17:50:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":54.0,"window_minutes":300,"resets_at":1783881382},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1784354760},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-07-12T18:40:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":43.0,"window_minutes":10080,"resets_at":1784354760},"plan_type":"plus"}}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: dayDir.appendingPathComponent("rollout-2026-07-12T17-50-00-tomb.jsonl"),
                        atomically: true, encoding: .utf8)
        let (result, _) = try CodexAdapter(roots: [root]).refreshUsage(state: ScanState())
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: result.rateLimits, settings: settings)
        let s = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                  settings: settings, now: date("2026-07-12T18:45:00Z"))
        XCTAssertNil(s.fiveHour.usedPercent, "週-only 快照後 5h 槽須被 tombstone(不 ghost 舊 54%)")
        XCTAssertEqual(s.weekly.usedPercent, 43, "週槽須保留(monotonic max(42,43))")

        // persisted-restart + 封存重放:absence 時點須持久化,重啟後被重掃重放的舊 5h 仍不得復活。
        let url = makeTempDir().appendingPathComponent("limits-state.json")
        let e1 = LimitEngine(stateURL: url)
        _ = e1.ingest(readings: result.rateLimits, settings: settings)          // 正常 → tombstone + 持久化 absence
        let e2 = LimitEngine(stateURL: url)                                     // 重啟(重載持久化狀態)
        _ = e2.ingest(readings: [result.rateLimits[0]], settings: settings)     // 封存重放舊 5h 快照
        XCTAssertNil(e2.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                   settings: settings, now: date("2026-07-12T18:45:00Z")).fiveHour.usedPercent,
                     "重啟後封存重放的舊 5h 不得復活已凍結的 5h(absence 須持久化)")

        // full reindex:排序重放全部讀數後仍凍結。
        let reeng = LimitEngine(stateURL: nil)
        _ = reeng.ingest(readings: result.rateLimits, settings: settings, fullReindex: true)
        XCTAssertNil(reeng.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-07-12T18:45:00Z")).fiveHour.usedPercent,
                     "full reindex 後仍凍結")

        // Codex 恢復 5h(更新的 300 窗)須解除凍結、正常顯示。
        let revive = LimitEngine(stateURL: nil)
        _ = revive.ingest(readings: result.rateLimits, settings: settings)
        _ = revive.ingest(readings: [RateLimitReading(providerId: "codex", observedAt: date("2026-07-12T20:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 8, windowMinutes: 300, resetsAt: date("2026-07-12T23:00:00Z")),
            secondary: RateLimitWindowReading(usedPercent: 44, windowMinutes: 10080, resetsAt: date("2026-07-18T06:06:00Z")))],
            settings: settings)
        XCTAssertEqual(revive.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                         settings: settings, now: date("2026-07-12T20:05:00Z")).fiveHour.usedPercent, 8,
                       "Codex 恢復 5h 後須解除凍結並顯示新值")
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

    // MARK: 換窗兩筆確認(後端「假重置」抖動防護)

    func windowReading(_ percent: Double, at: String, resetsAt: String) -> RateLimitReading {
        RateLimitReading(
            providerId: "codex",
            observedAt: date(at),
            primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300, resetsAt: date(resetsAt)),
            secondary: nil
        )
    }

    func weeklyReading(_ percent: Double, at: String, resetsAt: String) -> RateLimitReading {
        RateLimitReading(
            providerId: "codex",
            observedAt: date(at),
            primary: nil,
            secondary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 10080, resetsAt: date(resetsAt))
        )
    }

    func testExpiredWindowRolloverAdoptsFirstReading() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 現任窗口已過期 → 預期中的翻轉,第一筆讀數即接管並發出重置(原有行為)。
        let transitions = engine.ingest(readings: [windowReading(5, at: "2026-01-15T14:05:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(transitions.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T14:10:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 5)
    }

    func testLiveWindowTakeoverNeedsSecondReading() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 現任窗口仍存活卻宣稱換窗 = 抖動的唯一形態 → 第一筆只成為候選。
        let first = engine.ingest(readings: [windowReading(5, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertFalse(first.contains(.reset(providerId: "codex", window: "5h")))
        let mid = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                    settings: settings, now: date("2026-01-15T13:00:30Z"))
        XCTAssertEqual(mid.fiveHour.usedPercent, 80, "未確認前現任窗口不動")
        // 第二筆同窗讀數確認接管,重置轉變只發一次。
        let second = engine.ingest(readings: [windowReading(6, at: "2026-01-15T13:01:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(second.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T13:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 6)
        XCTAssertEqual(state.fiveHour.resetAt, date("2026-01-15T19:00:00Z"))
    }

    func testBackendFlapSingleReadingCannotPoisonWindow() {
        // 真實案例(2026-07-08 的 codex rollout):weekly 讀數途中多次被單筆「假重置」
        // (used≈0、resets_at = 觀測+7d)打斷,數秒後回滾。修正前,最後一次抖動的
        // resets_at 較晚,會永久佔住槽位並把之後所有真讀數當舊窗殘值丟棄。
        let engine = LimitEngine(stateURL: nil)
        let trueReset = "2026-01-14T03:51:00Z"
        var transitions: [LimitTransition] = []
        let sequence: [(Double, String, String)] = [
            (46, "2026-01-08T05:00:40Z", trueReset),
            (0, "2026-01-08T05:01:03Z", "2026-01-15T05:00:00Z"), // 抖動
            (46, "2026-01-08T05:01:17Z", trueReset), // 回滾
            (54, "2026-01-08T05:36:21Z", trueReset),
            (1, "2026-01-08T05:36:34Z", "2026-01-15T05:01:00Z"), // 抖動
            (54, "2026-01-08T05:36:50Z", trueReset), // 回滾
            (63, "2026-01-08T13:19:31Z", trueReset),
            (80, "2026-01-08T21:38:41Z", trueReset),
        ]
        for (percent, at, resets) in sequence {
            transitions += engine.ingest(readings: [weeklyReading(percent, at: at, resetsAt: resets)], settings: settings)
        }
        XCTAssertFalse(transitions.contains(.reset(providerId: "codex", window: "weekly")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-08T22:00:00Z"))
        XCTAssertEqual(state.weekly.usedPercent, 80)
        XCTAssertEqual(state.weekly.resetAt, date(trueReset))
    }

    func testPendingConfirmationSurvivesEngineReload() {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }

        let e1 = LimitEngine(stateURL: stateURL)
        _ = e1.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = e1.ingest(readings: [windowReading(5, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)

        // FSEvents 高頻批次下每批可能只有一筆新讀數:確認必須跨引擎實例/重啟累計。
        let e2 = LimitEngine(stateURL: stateURL)
        let transitions = e2.ingest(readings: [windowReading(6, at: "2026-01-15T13:01:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(transitions.contains(.reset(providerId: "codex", window: "5h")))
        let state = e2.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                  settings: settings, now: date("2026-01-15T13:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 6)
    }

    func testDuplicateReplayCannotConfirmPending() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let flap = windowReading(5, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")
        _ = engine.ingest(readings: [flap], settings: settings)
        let replay = engine.ingest(readings: [flap], settings: settings)
        XCTAssertFalse(replay.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T13:30:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 80, "同一筆讀數重放不得完成換窗確認")
    }

    func testOldObservationsAreFullyInert() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 觀測時間早於現任的殘留讀數:不得成為候選、不得確認、不得影響現值。
        var transitions = engine.ingest(readings: [windowReading(1, at: "2026-01-15T08:00:00Z", resetsAt: "2026-01-15T09:00:00Z")], settings: settings)
        transitions += engine.ingest(readings: [windowReading(2, at: "2026-01-15T08:30:00Z", resetsAt: "2026-01-15T09:00:00Z")], settings: settings)
        XCTAssertTrue(transitions.isEmpty)
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:30:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 80)
    }

    func testStaleCandidateWindowRejected() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        // 「新窗口」的 resets_at 在觀測當下已過期 → 必為殘留資料,連兩筆也不得接管。
        var transitions = engine.ingest(readings: [windowReading(3, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T10:20:00Z")], settings: settings)
        transitions += engine.ingest(readings: [windowReading(4, at: "2026-01-15T10:31:00Z", resetsAt: "2026-01-15T10:20:00Z")], settings: settings)
        XCTAssertTrue(transitions.isEmpty)
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:35:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 80)
    }

    func testSweepThenAdoptEmitsSingleReset() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let sweep = engine.sweepExpiredWindows(now: date("2026-01-15T14:01:00Z"))
        XCTAssertTrue(sweep.contains(.reset(providerId: "codex", window: "5h")))
        // sweep 已為過期發過重置 → 之後的接管不得重複通知。
        let adopt = engine.ingest(readings: [windowReading(5, at: "2026-01-15T14:05:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertFalse(adopt.contains(.reset(providerId: "codex", window: "5h")), "sweep 已發過重置,接管不得重複通知")
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T14:10:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 5)
    }

    func testOldSameWindowReplayKeepsPendingAlive() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [windowReading(5, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        // 現任窗的「舊」重放(觀測時間倒退)不是現任存活的證據,不得作廢候選。
        _ = engine.ingest(readings: [windowReading(79, at: "2026-01-15T09:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let confirm = engine.ingest(readings: [windowReading(6, at: "2026-01-15T13:01:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(confirm.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T13:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 6)
    }

    func testEarlierResetWindowRecoversFlapCapturedSlot() {
        // 抖動窗一旦搶佔(resets_at 永遠比真實窗晚),真實窗必須能以兩筆確認奪回 —
        // 若要求「resets_at 較晚者才可接管」,此槽位將凍結到假窗過期(原始事故)。
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [weeklyReading(1, at: "2026-01-08T21:24:00Z", resetsAt: "2026-01-15T05:01:00Z")], settings: settings) // 佔位的假窗
        var transitions = engine.ingest(readings: [weeklyReading(92, at: "2026-01-09T16:46:00Z", resetsAt: "2026-01-14T03:51:00Z")], settings: settings)
        transitions += engine.ingest(readings: [weeklyReading(93, at: "2026-01-09T16:47:00Z", resetsAt: "2026-01-14T03:51:00Z")], settings: settings)
        XCTAssertFalse(transitions.contains(.reset(providerId: "codex", window: "weekly")), "1%→93% 是奪回不是重置,不得誤發通知")
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-09T17:00:00Z"))
        XCTAssertEqual(state.weekly.usedPercent, 93, "resets_at 較早的真實窗必須能奪回被抖動佔位的槽位")
        XCTAssertEqual(state.weekly.resetAt, date("2026-01-14T03:51:00Z"))
    }

    func testPendingKeepsMonotonicMaxWithinCandidateWindow() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [windowReading(10, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        // 候選窗內亂序的較低樣本:接管值取單調最大,與同窗防護一致。
        let confirm = engine.ingest(readings: [windowReading(5, at: "2026-01-15T13:01:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(confirm.contains(.reset(providerId: "codex", window: "5h")))
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T13:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 10, "接管值不得被候選窗內較低的亂序樣本拉低")
    }

    func testOutOfOrderIncumbentReadingKeepsNewerPending() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [windowReading(5, at: "2026-01-15T13:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        // 亂序抵達的現任讀數(晚於現任觀測、但早於候選)不能證明現任在候選之後仍存活,
        // 不得作廢候選(稀疏來源否則永遠湊不滿兩筆)。
        _ = engine.ingest(readings: [windowReading(79, at: "2026-01-15T12:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        let confirm = engine.ingest(readings: [windowReading(6, at: "2026-01-15T13:01:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertTrue(confirm.contains(.reset(providerId: "codex", window: "5h")), "候選不得被亂序的較舊現任讀數打斷")
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T13:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 6)
    }

    func testNilResetIncumbentAdoptsResetBearingReadingImmediately() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [nilResetReading(45, at: "2026-01-15T10:00:00Z")], settings: settings)
        // 現任窗口無 resets_at → 無從證明存活;snapshot 來源可能長時間沒有第二筆新觀測,
        // 帶 resets_at 的重置後讀數必須第一筆即接管(原有行為)。
        let fresh = RateLimitReading(
            providerId: "claude-code",
            observedAt: date("2026-01-15T11:00:00Z"),
            primary: RateLimitWindowReading(usedPercent: 12, windowMinutes: 300,
                                            resetsAt: date("2026-01-15T15:00:00Z")),
            secondary: nil
        )
        let transitions = engine.ingest(readings: [fresh], settings: settings)
        XCTAssertTrue(transitions.contains(.reset(providerId: "claude-code", window: "5h")))
        let state = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T11:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 12)
        XCTAssertEqual(state.fiveHour.resetAt, date("2026-01-15T15:00:00Z"))
    }

    func testFreshIncumbentReadingCancelsPending() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [windowReading(0, at: "2026-01-15T10:30:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings) // 抖動 → 候選
        _ = engine.ingest(readings: [windowReading(81, at: "2026-01-15T10:31:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings) // 現任存活 → 候選作廢
        let after = engine.ingest(readings: [windowReading(1, at: "2026-01-15T10:32:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        XCTAssertFalse(after.contains(.reset(providerId: "codex", window: "5h")), "候選已被現任讀數作廢,新讀數需重新累計")
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:35:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 81)
    }

    func testThirdWindowCandidateReplacesPending() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [windowReading(80, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-15T14:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [windowReading(5, at: "2026-01-15T12:00:00Z", resetsAt: "2026-01-15T19:00:00Z")], settings: settings)
        // 與候選不同的第三個窗:重新累計,不得沿用前一候選的次數。
        _ = engine.ingest(readings: [windowReading(4, at: "2026-01-15T12:10:00Z", resetsAt: "2026-01-15T21:00:00Z")], settings: settings)
        let state1 = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                       settings: settings, now: date("2026-01-15T12:15:00Z"))
        XCTAssertEqual(state1.fiveHour.usedPercent, 80, "候選未確認前,存活的現任窗口不動")
        let confirm = engine.ingest(readings: [windowReading(6, at: "2026-01-15T12:20:00Z", resetsAt: "2026-01-15T21:00:00Z")], settings: settings)
        XCTAssertTrue(confirm.contains(.reset(providerId: "codex", window: "5h")))
        let state2 = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                       settings: settings, now: date("2026-01-15T12:25:00Z"))
        XCTAssertEqual(state2.fiveHour.usedPercent, 6)
        XCTAssertEqual(state2.fiveHour.resetAt, date("2026-01-15T21:00:00Z"))
    }

    func testLegacyStateFileWithoutPendingKeyDecodes() {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("limits-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        let legacy = """
        {"codex":{"primary":{"corrected":false,"expiryHandled":false,"history":[{"at":"2026-01-15T10:00:00Z","percent":42}],"observedAt":"2026-01-15T10:00:00Z","percent":42,"resetsAt":"2026-01-15T14:00:00Z","windowMinutes":300}}}
        """
        try? legacy.data(using: .utf8)?.write(to: stateURL)
        let engine = LimitEngine(stateURL: stateURL)
        let state = engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                                      settings: settings, now: date("2026-01-15T10:05:00Z"))
        XCTAssertEqual(state.fiveHour.usedPercent, 42, "舊版 state 檔(無 pending 欄位)必須可解碼")
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

    // MARK: 同窗官方下修(二筆確認;政策 = DATA_SOURCES「Limit calculation policy」通道 (c))

    /// 遠期 reset 的讀數(預設 helper 的 14:00 對 24h 閘測試太近)。
    func farReading(_ percent: Double, at: String) -> RateLimitReading {
        RateLimitReading(
            providerId: "codex",
            observedAt: date(at),
            primary: RateLimitWindowReading(usedPercent: percent, windowMinutes: 300,
                                            resetsAt: date("2026-01-19T00:00:00Z")),
            secondary: nil
        )
    }

    func state(_ engine: LimitEngine, now: String) -> ProviderLimitState {
        engine.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                          settings: settings, now: date(now))
    }

    // ① 單筆下修(任意幅度、任意新鮮)不改 percent。
    func testSameWindowSingleLowerReadingStaysPinned() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(20, at: "2026-01-15T10:10:00Z")], settings: settings)
        let s = state(engine, now: "2026-01-15T10:15:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 60)
        XCTAssertFalse(s.fiveHour.corrected)
    }

    // ② 兩筆 observedAt 嚴格遞增且降幅 >0.5 → 採納第二筆值 + corrected(official)。
    func testSameWindowDecreaseAdoptsAfterTwoNewerReadings() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:20:00Z")], settings: settings)
        let s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 45)
        XCTAssertTrue(s.fiveHour.corrected)
        XCTAssertEqual(s.fiveHour.correctedReason, .official)
        XCTAssertEqual(s.fiveHour.correctedAt, date("2026-01-15T10:20:00Z"))
    }

    // ③ 重放(observedAt 未前進)不可自我確認。
    func testSameWindowDecreaseReplayCannotSelfConfirm() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings) // 重放
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings) // 再重放
        let s = state(engine, now: "2026-01-15T10:15:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 60, "重放不得湊成第二筆確認")
        XCTAssertFalse(s.fiveHour.corrected)
    }

    // ④ 第二筆略高於第一筆、仍低於 current-0.5 → 屬同一次下修事件,採納最新值 45.4。
    func testSameWindowDecreaseSecondReadingSlightlyHigherStillConfirms() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45.0, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45.4, at: "2026-01-15T10:20:00Z")], settings: settings)
        let s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent!, 45.4, accuracy: 0.0001)
        XCTAssertTrue(s.fiveHour.corrected)
    }

    // ⑤ 上升讀數清空下修候選:60→45→61 之後,再一筆 45 不得立即採納(計數重新起算)。
    func testRisingReadingClearsPendingDecrease() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(61, at: "2026-01-15T10:20:00Z")], settings: settings)
        var s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 61)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:30:00Z")], settings: settings)
        s = state(engine, now: "2026-01-15T10:35:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 61, "候選已被上升讀數清空,單筆 45 不得採納")
        XCTAssertFalse(s.fiveHour.corrected)
    }

    // ⑥ fullReindex:單筆即可下修(reason=reindex),且一併清空下修候選。
    func testFullReindexClearsPendingDecreaseAndStampsReason() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(50, at: "2026-01-15T10:10:00Z")], settings: settings) // 候選 count=1
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:20:00Z")], settings: settings, fullReindex: true)
        var s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 45)
        XCTAssertTrue(s.fiveHour.corrected)
        XCTAssertEqual(s.fiveHour.correctedReason, .reindex)
        // 若 reindex 沒清掉先前的 50-候選,這筆 44 會被誤當第二筆確認而立即採納。
        _ = engine.ingest(readings: [farReading(44, at: "2026-01-15T10:30:00Z")], settings: settings)
        s = state(engine, now: "2026-01-15T10:35:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 45, "reindex 後的單筆下修必須重新起算")
    }

    // ⑦ epsilon 邊界:恰 -0.5 走單調路徑;超過 0.5 才進下修候選。
    func testDecreaseEpsilonBoundary() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(59.5, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(59.5, at: "2026-01-15T10:20:00Z")], settings: settings)
        var s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 60, "恰 0.5pt 的差不觸發下修")
        _ = engine.ingest(readings: [farReading(59.4, at: "2026-01-15T10:30:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(59.4, at: "2026-01-15T10:40:00Z")], settings: settings)
        s = state(engine, now: "2026-01-15T10:45:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent!, 59.4, accuracy: 0.0001)
    }

    // ⑧ 舊版 state 檔(無 pendingDecrease/correctedAt 欄位)可解碼,行為同現制;
    //    黏著的 legacy corrected:true(無 correctedAt,生產實際形狀)一律不 surface。
    func testLegacyStateWithoutNewFieldsDecodes() throws {
        let dir = makeTempDir()
        let stateURL = dir.appendingPathComponent("limits-state.json")
        let legacy = """
        {"codex":{"primary":{"percent":60,"resetsAt":"2026-01-19T00:00:00Z","observedAt":"2026-01-15T10:00:00Z","windowMinutes":300,"corrected":false,"expiryHandled":false,"history":[]},"secondary":{"percent":45,"resetsAt":"2026-01-19T00:00:00Z","observedAt":"2026-01-15T10:00:00Z","windowMinutes":10080,"corrected":true,"expiryHandled":false,"history":[]}}}
        """
        try legacy.data(using: .utf8)!.write(to: stateURL)
        let engine = LimitEngine(stateURL: stateURL)
        var s = state(engine, now: "2026-01-15T10:05:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 60, "舊 state 檔必須成功載入")
        XCTAssertFalse(s.fiveHour.corrected)
        // 2026-07-10 事故遺留的生產形狀:corrected=true 但無 correctedAt → 永不 surface(黏著註記治癒)。
        XCTAssertEqual(s.weekly.usedPercent, 45)
        XCTAssertFalse(s.weekly.corrected, "legacy corrected:true 無 correctedAt 不得 surface")
        XCTAssertNil(s.weekly.correctedAt)
        XCTAssertNil(s.weekly.correctedReason)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        s = state(engine, now: "2026-01-15T10:15:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 60, "單筆下修不得改變舊 state 的值")
    }

    // pendingDecrease 跨引擎重載持久化:count/observedAt 不因重啟歸零(對偶於換窗 pending 的 reload 測試)。
    func testPendingDecreaseSurvivesEngineReload() throws {
        let dir = makeTempDir()
        let stateURL = dir.appendingPathComponent("limits-state.json")
        let a = LimitEngine(stateURL: stateURL)
        _ = a.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = a.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings) // count=1 落盤

        let b = LimitEngine(stateURL: stateURL) // 重啟
        _ = b.ingest(readings: [farReading(45, at: "2026-01-15T10:20:00Z")], settings: settings) // 第二筆
        let s = b.limitState(providerId: "codex", ledger: UsageLedger(fileURL: nil),
                             settings: settings, now: date("2026-01-15T10:25:00Z"))
        XCTAssertEqual(s.fiveHour.usedPercent, 45, "候選需跨重啟累計,第二筆即採納")
        XCTAssertTrue(s.fiveHour.corrected)
        XCTAssertEqual(s.fiveHour.correctedReason, .official)
    }

    // ⑨ corrected 是一次性事件:採納後 24h 內 surface,之後自動熄滅(UI/報告/CLI 同源)。
    func testCorrectedSurfacesOnly24Hours() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:20:00Z")], settings: settings)
        var s = state(engine, now: "2026-01-16T09:20:00Z") // +23h
        XCTAssertTrue(s.fiveHour.corrected)
        s = state(engine, now: "2026-01-16T11:20:00Z") // +25h(窗口 01-19 才過期,仍存活)
        XCTAssertFalse(s.fiveHour.corrected, "24h 後 corrected 自動熄滅")
        XCTAssertEqual(s.fiveHour.usedPercent, 45, "percent 本身不受閘影響")
    }

    // ⑩ primary-only 讀數不得驚動 weekly 槽(per-window 拆筆的引擎端保證)。
    func testPrimaryOnlyReadingsDoNotDisturbStaleWeekly() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [reading(60, at: "2026-01-15T10:00:00Z", resetsAt: "2026-01-19T00:00:00Z", weekly: 50)],
                          settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:10:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(44, at: "2026-01-15T10:20:00Z")], settings: settings)
        let s = state(engine, now: "2026-01-15T10:25:00Z")
        XCTAssertEqual(s.weekly.usedPercent, 50, "primary-only 讀數不得改動 weekly")
        XCTAssertFalse(s.weekly.corrected)
    }

    // 亂序遲到的高值讀數(觀測時間早於候選)不得作廢下修候選(與換窗 pending 同律)。
    func testOutOfOrderHighReadingKeepsPendingDecrease() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:00:00Z")], settings: settings)
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:20:00Z")], settings: settings) // 候選@10:20
        _ = engine.ingest(readings: [farReading(60, at: "2026-01-15T10:10:00Z")], settings: settings) // 亂序遲到
        _ = engine.ingest(readings: [farReading(45, at: "2026-01-15T10:30:00Z")], settings: settings) // 第二筆確認
        let s = state(engine, now: "2026-01-15T10:35:00Z")
        XCTAssertEqual(s.fiveHour.usedPercent, 45, "10:10 的舊讀數無法反證 10:20 之後的下修")
        XCTAssertTrue(s.fiveHour.corrected)
        XCTAssertEqual(s.fiveHour.correctedReason, .official)
    }

    // plan-only 讀數:planType 落地、窗口完全不受影響;statusline 失效時 chip 不消失。
    func testPlanOnlyReadingSetsPlanTypeWithoutWindows() {
        let engine = LimitEngine(stateURL: nil)
        _ = engine.ingest(readings: [
            RateLimitReading(providerId: "claude-code", observedAt: date("2026-01-15T10:00:00Z"),
                             primary: nil, secondary: nil, planType: "Max 20x")
        ], settings: settings)
        // 無任何窗口讀數 → claude 走預算估算路徑;planType 仍須存在。
        let s = engine.limitState(providerId: "claude-code", ledger: UsageLedger(fileURL: nil),
                                  settings: settings, now: date("2026-01-15T10:05:00Z"))
        XCTAssertEqual(s.planType, "Max 20x")
        XCTAssertNil(s.fiveHour.usedPercent)
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

// MARK: - Grok Code adapter

final class GrokCodeAdapterTests: XCTestCase {
    let encCwd = "%2FUsers%2Fdev%2Fprojects%2Fgrok-demo"
    let sessionUUID = "11111111-1111-1111-1111-111111111111"
    let sentinel = "SENTINEL_DO_NOT_LEAK_9f3a"
    let summaryJSON = "{\"info\":{\"id\":\"11111111-1111-1111-1111-111111111111\",\"cwd\":\"/Users/dev/projects/grok-demo\"},\"current_model_id\":\"grok-4.5\"}"

    // 建 <root>/sessions/<encCwd>/<uuid>/ 結構,寫入給定 updates.jsonl 行與可選 meta,回傳 sessions 目錄。
    func writeSession(lines: [String], summary: String?, signals: String?) throws -> URL {
        let root = makeTempDir()
        let sessions = root.appendingPathComponent("sessions")
        let dir = sessions.appendingPathComponent(encCwd).appendingPathComponent(sessionUUID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: dir.appendingPathComponent("updates.jsonl"))
        if let summary { try summary.data(using: .utf8)!.write(to: dir.appendingPathComponent("summary.json")) }
        if let signals { try signals.data(using: .utf8)!.write(to: dir.appendingPathComponent("signals.json")) }
        return sessions
    }

    func updatesURL(inSessions sessions: URL) -> URL {
        sessions.appendingPathComponent(encCwd).appendingPathComponent(sessionUUID)
            .appendingPathComponent("updates.jsonl")
    }

    // 合成一筆帶 totalTokens 的 token 行;ts 為頂層 timestamp。
    func tokenLine(ts: Int, total: Int, eventId: String?, agentMs: Int? = nil, text: String = "synthetic") -> String {
        var meta = "\"totalTokens\":\(total)"
        if let eventId { meta += ",\"eventId\":\"\(eventId)\"" }
        if let agentMs { meta += ",\"agentTimestampMs\":\(agentMs)" }
        return "{\"timestamp\":\(ts),\"method\":\"session/update\",\"params\":{\"sessionId\":\"\(sessionUUID)\","
            + "\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"\(text)\"}},"
            + "\"_meta\":{\(meta)}}}"
    }

    func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line + "\n").data(using: .utf8)!)
        try handle.close()
    }

    // 把 Fixtures/grok/* 複製進臨時 session 結構,回傳 sessions 目錄。
    func makeFixtureSessions() throws -> URL {
        let root = makeTempDir()
        let dir = root.appendingPathComponent("sessions").appendingPathComponent(encCwd)
            .appendingPathComponent(sessionUUID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["updates.jsonl", "summary.json", "signals.json"] {
            try FileManager.default.copyItem(at: fixtureURL("grok/\(name)"),
                                             to: dir.appendingPathComponent(name))
        }
        return root.appendingPathComponent("sessions")
    }

    // 1) 成長 / 壓縮倒退 / 非 token 行 / model / URL-decoded cwd。
    func testParsesGrowthCompactionModelAndProject() throws {
        // billingLogFiles: [] — 隔離本機 ~/.grok/logs,rateLimits 應為空
        let adapter = GrokCodeAdapter(roots: [try makeFixtureSessions()], billingLogFiles: [])
        let (result, state) = try adapter.refreshUsage(state: ScanState())

        // 成長 1000→2500→2900、非 token 行略過、壓縮倒退到 400(不產生事件、重設基準)、再成長到 900。
        // 期望差值:1000, 1500, 400, 500;id 取 eventId。
        XCTAssertEqual(result.events.count, 4)
        XCTAssertEqual(result.events.map { $0.tokens.input }, [1000, 1500, 400, 500])
        XCTAssertEqual(result.events.map { $0.id }, ["gk:evt-1", "gk:evt-2", "gk:evt-3", "gk:evt-6"])
        for e in result.events {
            XCTAssertEqual(e.providerId, "grok-code")
            XCTAssertEqual(e.tokens.output, 0)
            XCTAssertEqual(e.tokens.cacheRead, 0)
            XCTAssertEqual(e.tokens.total, e.tokens.input)
            XCTAssertEqual(e.modelId, "grok-4.5")
            XCTAssertEqual(e.projectId, "/Users/dev/projects/grok-demo")
            XCTAssertEqual(e.projectName, "grok-demo")
            XCTAssertEqual(e.sourceKind, "grok-session")
        }
        // 頂層 timestamp 為 epoch 秒
        XCTAssertEqual(result.events[0].timestamp.timeIntervalSince1970, 1783692000)
        XCTAssertEqual(result.events[3].timestamp.timeIntervalSince1970, 1783692400)
        // grok 無本機限額
        XCTAssertEqual(result.rateLimits.count, 0)
        // 掃描進度記錄了單一 updates.jsonl 的位移
        XCTAssertEqual(state.files.count, 1)
        XCTAssertGreaterThan(state.files.values.first!.offset, 0)
    }

    // 2) 壓縮倒退:不產生負/零事件,基準重設。
    func testCompactionRegressionEmitsNoNegativeOrZero() throws {
        let lines = [tokenLine(ts: 1_000_000_000, total: 1000, eventId: "a"),
                     tokenLine(ts: 1_000_000_100, total: 400, eventId: "b"),   // 倒退
                     tokenLine(ts: 1_000_000_200, total: 900, eventId: "c")]   // 由 400 成長 → 500
        let adapter = GrokCodeAdapter(roots: [try writeSession(lines: lines, summary: summaryJSON, signals: nil)], billingLogFiles: [])
        let (result, _) = try adapter.refreshUsage(state: ScanState())

        XCTAssertEqual(result.events.count, 2, "倒退那筆不得產生事件")
        XCTAssertEqual(result.events.map { $0.tokens.input }, [1000, 500])
        XCTAssertEqual(result.events.map { $0.id }, ["gk:a", "gk:c"])
        for e in result.events { XCTAssertGreaterThan(e.tokens.total, 0) }
        XCTAssertFalse(result.events.contains { $0.id == "gk:b" })
    }

    // 3) 增量:第二次無新事件;追加一行後只回傳新差值。
    func testIncrementalEmitsOnlyNewDelta() throws {
        let sessions = try makeFixtureSessions()
        let adapter = GrokCodeAdapter(roots: [sessions], billingLogFiles: [])
        let (r1, s1) = try adapter.refreshUsage(state: ScanState())
        let (r2, s2) = try adapter.refreshUsage(state: s1)
        XCTAssertFalse(r1.events.isEmpty)
        XCTAssertTrue(r2.events.isEmpty, "無新內容不得回傳事件")

        // 基準停在 900(fixture 末筆);追加累計 1500 → 差值 600。
        try appendLine(tokenLine(ts: 1783692500, total: 1500, eventId: "evt-7"),
                       to: updatesURL(inSessions: sessions))
        let (r3, _) = try adapter.refreshUsage(state: s2)
        XCTAssertEqual(r3.events.count, 1)
        XCTAssertEqual(r3.events[0].tokens.input, 600)
        XCTAssertEqual(r3.events[0].id, "gk:evt-7")
        XCTAssertEqual(r3.events[0].modelId, "grok-4.5", "增量掃描仍讀 summary.json 保留 model")
    }

    // 4) 檔案縮短/截斷:offset > size → 從 0 全掃,事件以相同 id 重播(去重可吸收)。
    func testShrinkTriggersFullRescanWithStableIds() throws {
        let lines = [tokenLine(ts: 1_000_000_000, total: 1000, eventId: "evt-1"),
                     tokenLine(ts: 1_000_000_100, total: 2500, eventId: "evt-2"),
                     tokenLine(ts: 1_000_000_200, total: 2900, eventId: "evt-3")]
        let sessions = try writeSession(lines: lines, summary: summaryJSON, signals: nil)
        let adapter = GrokCodeAdapter(roots: [sessions], billingLogFiles: [])
        let (r1, s1) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(r1.events.count, 3)

        // 重寫成更短的檔(位元組數小於已存 offset)→ 觸發從 0 全掃、重置上下文。
        let shortBody = [tokenLine(ts: 1_000_000_000, total: 1000, eventId: "evt-1"),
                         tokenLine(ts: 1_000_000_100, total: 2500, eventId: "evt-2")]
            .joined(separator: "\n") + "\n"
        try shortBody.data(using: .utf8)!.write(to: updatesURL(inSessions: sessions))

        let (r2, _) = try adapter.refreshUsage(state: s1)
        XCTAssertEqual(r2.events.map { $0.id }, ["gk:evt-1", "gk:evt-2"], "同一 id 重播")
        XCTAssertEqual(r2.events.map { $0.tokens.input }, [1000, 1500])
    }

    // 5) eventId 後援:無 eventId → id = gk:<uuid>:<offset>(首行位移 0)。
    func testEventIdFallbackToSessionAndOffset() throws {
        let sessions = try writeSession(lines: [tokenLine(ts: 1_000_000_000, total: 700, eventId: nil)],
                                        summary: summaryJSON, signals: nil)
        let (result, _) = try GrokCodeAdapter(roots: [sessions], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].id, "gk:\(sessionUUID):0")
    }

    // 6) 時間戳:epoch 秒 / >1e12 視為毫秒 / agentTimestampMs 後援 / 兩者皆無則跳過。
    func testTimestampSecondsMillisFallbackAndSkip() throws {
        // (A) epoch 秒
        let a = try writeSession(lines: [tokenLine(ts: 1_735_000_000, total: 100, eventId: "a")],
                                 summary: summaryJSON, signals: nil)
        let (ra, _) = try GrokCodeAdapter(roots: [a], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(ra.events.count, 1)
        XCTAssertEqual(ra.events[0].timestamp.timeIntervalSince1970, 1_735_000_000)

        // (B) 毫秒量級(>1e12)的頂層 timestamp 視為毫秒
        let b = try writeSession(lines: [tokenLine(ts: 1_735_000_000_000, total: 100, eventId: "b")],
                                 summary: summaryJSON, signals: nil)
        let (rb, _) = try GrokCodeAdapter(roots: [b], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(rb.events.count, 1)
        XCTAssertEqual(rb.events[0].timestamp.timeIntervalSince1970, 1_735_000_000)

        // (C) 無頂層 timestamp,但有 agentTimestampMs → 後援(毫秒)
        let cLine = "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"\(sessionUUID)\","
            + "\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"x\"}},"
            + "\"_meta\":{\"totalTokens\":100,\"eventId\":\"c\",\"agentTimestampMs\":1735000000000}}}"
        let c = try writeSession(lines: [cLine], summary: summaryJSON, signals: nil)
        let (rc, _) = try GrokCodeAdapter(roots: [c], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(rc.events.count, 1)
        XCTAssertEqual(rc.events[0].timestamp.timeIntervalSince1970, 1_735_000_000)

        // (D) 無 timestamp 也無 agentTimestampMs → 跳過(0 事件)
        let dLine = "{\"method\":\"session/update\",\"params\":{\"sessionId\":\"\(sessionUUID)\","
            + "\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"x\"}},"
            + "\"_meta\":{\"totalTokens\":100,\"eventId\":\"d\"}}}"
        let d = try writeSession(lines: [dLine], summary: summaryJSON, signals: nil)
        let (rd, _) = try GrokCodeAdapter(roots: [d], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(rd.events.count, 0)
    }

    // 7) 隱私:content 內含 sentinel;emitted 事件任何欄位都不得出現 sentinel。
    func testPrivacySentinelNeverLeaks() throws {
        let adapter = GrokCodeAdapter(roots: [try makeFixtureSessions()], billingLogFiles: [])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertFalse(result.events.isEmpty)
        for e in result.events {
            XCTAssertFalse(e.id.contains(sentinel))
            XCTAssertFalse((e.projectId ?? "").contains(sentinel))
            XCTAssertFalse((e.projectName ?? "").contains(sentinel))
            XCTAssertFalse((e.modelId ?? "").contains(sentinel))
            XCTAssertFalse((e.sourcePath ?? "").contains(sentinel))
            XCTAssertFalse(e.sourceKind.contains(sentinel))
        }
        // 帶 sentinel content 的那筆(evt-2)仍正確計入(差值 1500),證明只擷取計數器而非內容。
        let e2 = result.events.first { $0.id == "gk:evt-2" }
        XCTAssertNotNil(e2)
        XCTAssertEqual(e2?.tokens.input, 1500)
    }

    // 8) 可用性:注入 roots 指到臨時目錄,存在/不存在切換(roots 動態依存在性重算)。
    func testAvailabilityFollowsRootExistence() throws {
        let missing = makeTempDir().appendingPathComponent("sessions") // 尚未建立
        let adapter = GrokCodeAdapter(roots: [missing], billingLogFiles: [])
        XCTAssertFalse(adapter.detectAvailability().available)
        XCTAssertTrue(adapter.roots.isEmpty)

        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        XCTAssertTrue(adapter.detectAvailability().available)
        XCTAssertEqual(adapter.roots.count, 1)
    }

    // 10) 預設啟用:grok-code 必須在 CoreSettings 預設集合內(新安裝開箱即掃;
    //     未安裝 grok 時由 OnboardingCard 呈現 unavailable,已存檔設定不受影響)。
    func testGrokEnabledInDefaultSettings() {
        XCTAssertTrue(CoreSettings().enabledProviders.contains("grok-code"))
    }

    // 11) 生成價目不得自動為 grok-code 計價(context-growth 粗估不可偽裝成精確成本);
    //     手動維護價目與使用者覆寫仍可刻意定價 — 此處驗證預設載入路徑必然排除。
    func testGeneratedPricesNeverAutoPriceGrok() {
        let registry = PricingRegistry.loadDefault(overridesURL: nil)
        let event = UsageEvent(
            id: "gk:pricing-test", providerId: "grok-code", projectId: nil, projectName: nil,
            modelId: "grok-4.3", // 存在於 model-prices-generated.json,仍不得自動套價
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            tokens: TokenBreakdown(input: 1000, output: 0, cacheRead: 0),
            sourceKind: "grok-session", sourcePath: nil
        )
        let cost = registry.cost(of: event)
        XCTAssertEqual(cost.knownUSD, 0)
        XCTAssertEqual(cost.unknownModelTokens, 1000, "生成價目的 grok 條目必須被排除在自動計價之外")
    }

    // 12) 生成排除的對偶:curated 人工驗證條目「刻意計價」的通道必須有效
    //     (grok-4.5 已依 docs.x.ai 驗證入表;成本為低估值,見 DATA_SOURCES.md)。
    func testCuratedEntryDeliberatelyPricesGrok() {
        let registry = PricingRegistry.loadDefault(overridesURL: nil)
        let event = UsageEvent(
            id: "gk:curated-pricing-test", providerId: "grok-code", projectId: nil, projectName: nil,
            modelId: "grok-4.5",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            tokens: TokenBreakdown(input: 1_000_000, output: 0, cacheRead: 0),
            sourceKind: "grok-session", sourcePath: nil
        )
        let cost = registry.cost(of: event)
        XCTAssertEqual(cost.knownUSD, 2.0, accuracy: 0.001, "curated grok-4.5 必須以 $2/M input 計價")
        XCTAssertEqual(cost.unknownModelTokens, 0)
    }

    // 9) model 後援:summary 缺 current_model_id → 用 signals.primaryModelId;皆缺則 nil。
    func testModelFallbackToSignalsThenNil() throws {
        let noModelSummary = "{\"info\":{\"id\":\"\(sessionUUID)\",\"cwd\":\"/Users/dev/projects/grok-demo\"}}"
        let signals = "{\"primaryModelId\":\"grok-4.5-fast\",\"modelsUsed\":[\"grok-4.5-fast\"],\"turnCount\":1}"

        // summary 缺 model → 用 signals.primaryModelId
        let s1 = try writeSession(lines: [tokenLine(ts: 1_000_000_000, total: 500, eventId: "a")],
                                  summary: noModelSummary, signals: signals)
        let (r1, _) = try GrokCodeAdapter(roots: [s1], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(r1.events.count, 1)
        XCTAssertEqual(r1.events[0].modelId, "grok-4.5-fast")
        XCTAssertEqual(r1.events[0].projectId, "/Users/dev/projects/grok-demo")

        // summary 缺 model 且無 signals → modelId 為 nil
        let s2 = try writeSession(lines: [tokenLine(ts: 1_000_000_000, total: 500, eventId: "a")],
                                  summary: noModelSummary, signals: nil)
        let (r2, _) = try GrokCodeAdapter(roots: [s2], billingLogFiles: []).refreshUsage(state: ScanState())
        XCTAssertEqual(r2.events.count, 1)
        XCTAssertNil(r2.events[0].modelId)
    }

    // MARK: 訂閱方案標籤(billing 行尾部窄解碼)

    func testBillingTierParsedFromLogTail() throws {
        let dir = makeTempDir()
        let log = dir.appendingPathComponent("unified.jsonl")
        // 混合行:非 billing 雜訊 / 舊 tier / 最新 tier(取最後一筆非空)。
        try """
        {"ts":"2026-07-01T00:00:00Z","msg":"session start","ctx":{"foo":1}}
        {"ts":"2026-07-02T00:00:00Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":1.0},"subscriptionTier":"Free"}}
        not-even-json
        {"ts":"2026-07-10T00:00:00Z","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":1.0},"subscriptionTier":"SuperGrok"}}
        """.data(using: .utf8)!.write(to: log)
        XCTAssertEqual(GrokCodeAdapter.readSubscriptionTier(from: [log]), "SuperGrok")

        // 尾部有界:tailBytes 小到截進前面的行(部分行解析失敗被跳過),仍能解析完整的最後一行。
        XCTAssertEqual(GrokCodeAdapter.readSubscriptionTier(from: [log], tailBytes: 160), "SuperGrok")

        // 缺檔 → nil(絕不猜值)。
        XCTAssertNil(GrokCodeAdapter.readSubscriptionTier(from: [dir.appendingPathComponent("nope.jsonl")]))
    }

    func testPlanOnlyReadingEmittedThroughRefresh() throws {
        let dir = makeTempDir()
        let log = dir.appendingPathComponent("unified.jsonl")
        try """
        {"ts":"2026-07-10T00:00:00Z","msg":"billing: fetched credits config","ctx":{"subscriptionTier":"SuperGrok"}}
        """.data(using: .utf8)!.write(to: log)
        let adapter = GrokCodeAdapter(roots: [try makeFixtureSessions()], billingLogFiles: [log])
        let (result, _) = try adapter.refreshUsage(state: ScanState())
        XCTAssertEqual(result.rateLimits.count, 1)
        XCTAssertEqual(result.rateLimits[0].planType, "SuperGrok")
        XCTAssertNil(result.rateLimits[0].primary, "grok 仍不回報任何用量百分比")
        XCTAssertNil(result.rateLimits[0].secondary)
    }
}

// MARK: - fmtUSD(千分位金額)

final class FmtUSDTests: XCTestCase {
    /// 千分位契約(R3):分隔符固定 ,/.,不隨 locale 漂移;decimals 參數化。
    func testThousandsSeparatorAndDecimals() {
        XCTAssertEqual(ReportGenerator.fmtUSD(1234.56), "$1,234.56")
        XCTAssertEqual(ReportGenerator.fmtUSD(1000), "$1,000.00")
        XCTAssertEqual(ReportGenerator.fmtUSD(1000, decimals: 0), "$1,000")
        XCTAssertEqual(ReportGenerator.fmtUSD(4196.18), "$4,196.18")
        XCTAssertEqual(ReportGenerator.fmtUSD(0.5), "$0.50")
        XCTAssertEqual(ReportGenerator.fmtUSD(1234567.891, decimals: 3), "$1,234,567.891")
        // R4:fmtUSD/fmtTokens 皆為 grouped() 薄包裝(使用者提議的單一出處抽取)。
        XCTAssertEqual(ReportGenerator.grouped(1000, decimals: 1), "1,000.0")
    }

    /// token 格式單一方言(R4):≥1e9 走 B 分支(修 Trends 舊 tokenLabel 的 "1000.0M");
    /// 進位溢位升級(codex):係數四捨五入到 1000 → 自動升一級,永不見 "1,000.xxM"。
    func testFmtTokensUnifiedDialect() {
        XCTAssertEqual(ReportGenerator.fmtTokens(1_000_000_000), "1.00B")
        XCTAssertEqual(ReportGenerator.fmtTokens(1_914_600_000), "1.91B")
        XCTAssertEqual(ReportGenerator.fmtTokens(608_900_000), "608.90M")
        XCTAssertEqual(ReportGenerator.fmtTokens(563_500_000), "563.50M")
        XCTAssertEqual(ReportGenerator.fmtTokens(1_500), "1.5k")
        XCTAssertEqual(ReportGenerator.fmtTokens(950), "950")
        // 進位邊界(codex R4 P3 指名案例)
        XCTAssertEqual(ReportGenerator.fmtTokens(999_999_999), "1.00B")
        XCTAssertEqual(ReportGenerator.fmtTokens(999_999), "1.00M")
        XCTAssertEqual(ReportGenerator.fmtTokens(999_949), "999.9k")
        XCTAssertEqual(ReportGenerator.fmtTokens(-999_999_999), "-1.00B")
    }
}

// MARK: - LocalTime(人讀時間戳)

final class LocalTimeTests: XCTestCase {
    func testFormatsWithUTCOffset() {
        let d = date("2026-07-12T09:21:17Z")
        XCTAssertEqual(LocalTime.format(d, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!),
                       "2026-07-12 17:21:17 (UTC+8)")
        XCTAssertEqual(LocalTime.format(d, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "2026-07-12 09:21:17 (UTC+0)")
        // 半時區(印度標準時間)顯示分鐘
        XCTAssertEqual(LocalTime.format(d, timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!),
                       "2026-07-12 14:51:17 (UTC+5:30)")
        XCTAssertEqual(LocalTime.format(d, timeZone: TimeZone(secondsFromGMT: -7 * 3600)!),
                       "2026-07-12 02:21:17 (UTC-7)")
    }
}
