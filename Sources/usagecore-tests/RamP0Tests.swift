import Foundation
import UsageCore

// RAM P0(2026-09-02)測試面。
// C:fiveHourBlock 串流入口 —— array/streaming parity + 絕對語義 pin(防兩入口同壞)。
// D:scan-state fingerprint 讀取快取 + 「canonical == durable 才寫」——
//    跨行程 oracle(A 快取後,B 改 durable 狀態,A 下一輪必須看見且不得 clobber)、
//    idle tick 不重寫(inode/mtime 不動)、malformed 仍照 #44 契約 A 中止。
// B:retention 可觀測性 characterization(production 凍結;只把現況語義釘成可執行事實):
//    cutoff 已過、物理壓縮未跑 → 過期事件對無下限聚合仍可見;
//    合成 post-cutoff 常態 → compactWouldAct 逐分鐘恆真、raw-preserving 每次 .applied(無節流)。

/// shim 無全域 XCTFail;本檔自備(語義同 XCTest:記一次斷言、記一次失敗)。
private func XCTFail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    TestRun.assertions += 1
    TestRun.fail(message, file: file, line: line)
}

private func ramTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("aipet-ramp0-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // realpath 正規化(/var → /private/var):adapter 的 scan-state key 用列舉到的實體路徑,
    // 測試以 path 查字典必須同一表示。
    guard let rp = realpath(url.path, nil) else { return url }
    defer { free(rp) }
    return URL(fileURLWithPath: String(cString: rp), isDirectory: true)
}

private func ramEvent(_ id: String, _ providerId: String, at ts: Date, input: Int) -> UsageEvent {
    UsageEvent(id: id, providerId: providerId, timestamp: ts,
               tokens: TokenBreakdown(input: input), sourceKind: "test")
}

// MARK: - C:fiveHourBlock parity

final class FiveHourBlockParityTests: XCTestCase {
    func testStreamingEntryMatchesArrayEntryAndPinnedSemantics() throws {
        let dir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = ISO8601.parse("2026-09-02T10:30:00Z")!
        let ledger = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
        // 宣告輸入集(窗分組 tz-invariant,見下方 pin 註解):第一窗 = c1(+c2,相隔 1h);
        // 第二窗 = c3(距 c1 5.5h,必越窗)+c4;夾雜 codex 事件必須被 providerId 過濾。
        let c1 = ramEvent("c1", "claude-code", at: now.addingTimeInterval(-390 * 60), input: 10)
        let c2 = ramEvent("c2", "claude-code", at: now.addingTimeInterval(-330 * 60), input: 20)
        let c3 = ramEvent("c3", "claude-code", at: now.addingTimeInterval(-60 * 60), input: 40)
        let c4 = ramEvent("c4", "claude-code", at: now.addingTimeInterval(-30 * 60), input: 80)
        let x1 = ramEvent("x1", "codex", at: now.addingTimeInterval(-360 * 60), input: 999)
        let x2 = ramEvent("x2", "codex", at: now.addingTimeInterval(-45 * 60), input: 999)
        XCTAssertEqual(ledger.append([c1, x1, c2, c3, x2, c4]), 6)

        let interval = DateInterval(start: now.addingTimeInterval(-8 * 86400), end: now)
        let viaArray = LimitEngine.fiveHourBlock(
            events: ledger.events(in: interval, providerId: "claude-code"), now: now)
        let viaStream = LimitEngine.fiveHourBlock(
            ledger: ledger, interval: interval, providerId: "claude-code", now: now)

        // parity
        XCTAssertEqual(viaArray?.start, viaStream?.start)
        XCTAssertEqual(viaArray?.end, viaStream?.end)
        XCTAssertEqual(viaArray?.tokens, viaStream?.tokens)
        // 絕對語義 pin,tz-portable(xcheck r1 sol S1:舊版釘 UTC 絕對值,在非整點
        // offset 時區(如 +05:45)假紅)。真正契約 =「Calendar.current 的本地整點
        // floor 開窗、5 小時關窗」:以同一測試環境的 local calendar components 斷言
        // floor 性質與視窗關係,不從 UTC 字串/固定 offset 推。窗分組(c1,c2 同窗;
        // c3,c4 新窗)對任意 ≤1h 粒度的 offset 恆成立(c2−c1=1h<4h≤窗餘;
        // c3−c1=5.5h>5h≥窗長)。tokens = c3+c4(codex 排除)。
        guard let start = viaStream?.start, let end = viaStream?.end else {
            return XCTFail("第二窗應為 active(now < end)")
        }
        let floorComps = Calendar.current.dateComponents([.minute, .second], from: start)
        XCTAssertEqual(floorComps.minute, 0, "窗起點應為本地整點(minute==0)")
        XCTAssertEqual(floorComps.second, 0, "窗起點應為本地整點(second==0)")
        XCTAssertTrue(start <= c3.timestamp && c3.timestamp < start.addingTimeInterval(3600),
                      "c3 應落在其本地整點 floor 起的一小時內")
        XCTAssertEqual(end, start.addingTimeInterval(5 * 3600), "end == start + 5h")
        XCTAssertEqual(viaStream?.tokens, 120)

        // array 入口的防禦性排序仍在:亂序輸入結果不變。
        let shuffled = LimitEngine.fiveHourBlock(events: [c4, c1, c3, c2], now: now)
        XCTAssertEqual(shuffled?.start, viaStream?.start)
        XCTAssertEqual(shuffled?.tokens, viaStream?.tokens)

        // 視窗已收(now 越過 blockEnd)→ 兩入口皆 nil。
        let later = now.addingTimeInterval(10 * 3600)
        XCTAssertNil(LimitEngine.fiveHourBlock(
            events: ledger.events(in: interval, providerId: "claude-code"), now: later))
        XCTAssertNil(LimitEngine.fiveHourBlock(
            ledger: ledger, interval: interval, providerId: "claude-code", now: later))

        // 空區間 → 兩入口皆 nil。
        let empty = DateInterval(start: now.addingTimeInterval(-16 * 86400),
                                 end: now.addingTimeInterval(-15 * 86400))
        XCTAssertNil(LimitEngine.fiveHourBlock(
            events: ledger.events(in: empty, providerId: "claude-code"), now: now))
        XCTAssertNil(LimitEngine.fiveHourBlock(
            ledger: ledger, interval: empty, providerId: "claude-code", now: now))
    }
}

// MARK: - D:scan-state 快取與寫出省略

final class ScanStateCacheTests: XCTestCase {
    private func statIdentity(_ url: URL) -> (ino: UInt64, mtimeNs: Int64, size: Int64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(st.st_ino),
                Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                Int64(st.st_size))
    }

    /// 最小可掃 codex rollout(格式照 CodexPrivacyTests 的既有 fixture;timestamp 用當下,
    /// 避免 retention 干擾)。回傳 (root, rolloutPath)。
    private func writeCodexFixture(input: Int) throws -> (root: URL, rollout: URL) {
        let root = ramTempDir()
        let dir = root.appendingPathComponent("2026/09/02")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = ISO8601.format(Date().addingTimeInterval(-3600))
        let t1 = ISO8601.format(Date().addingTimeInterval(-3500))
        let lines = [
            #"{"timestamp":"\#(t0)","type":"session_meta","payload":{"id":"ramp0-s1","cwd":"/tmp/ramp0/proj"}}"#,
            #"{"timestamp":"\#(t1)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"output_tokens":10,"total_tokens":\#(input + 10)}},"rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1768475700},"secondary":null,"plan_type":"plus"}}}"#,
        ]
        let url = dir.appendingPathComponent("rollout-2026-09-02T08-00-00-ramp0.jsonl")
        try lines.joined(separator: "\n").appending("\n").data(using: .utf8)!.write(to: url)
        return (root, url)
    }

    private func runRefresh(_ c: UsageCoordinator) -> RefreshOutcome {
        var out: RefreshOutcome!
        let sem = DispatchSemaphore(value: 0)
        Task { out = await c.refresh(); sem.signal() }
        sem.wait()
        return out
    }

    func testIdleRefreshSkipsScanStateRewrite() throws {
        let dataDir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let (root, rollout) = try writeCodexFixture(input: 100)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanURL = dataDir.appendingPathComponent("scan-state.json")
        let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings(),
                                           adapters: [CodexAdapter(roots: [root])])

        let out1 = runRefresh(coordinator)
        XCTAssertFalse(out1.skipped)
        XCTAssertEqual(out1.insertedEvents, 1)
        guard let id1 = statIdentity(scanURL) else { return XCTFail("scan-state 未建立") }

        // 無任何來源變動的 idle tick:不得重寫(inode+mtime+size 全不動)。
        let out2 = runRefresh(coordinator)
        XCTAssertFalse(out2.skipped)
        XCTAssertEqual(out2.insertedEvents, 0)
        guard let id2 = statIdentity(scanURL) else { return XCTFail("scan-state 消失") }
        XCTAssertEqual(id1.ino, id2.ino, "idle tick 不得原子替換 scan-state(inode 應不變)")
        XCTAssertEqual(id1.mtimeNs, id2.mtimeNs, "idle tick 不得重寫 scan-state(mtime 應不變)")
        XCTAssertEqual(id1.size, id2.size)

        // 來源真的變了 → 照舊寫出(省略絕不犧牲 freshness)。
        // 注意:codex totals 是「累計值」,追加行必須高於首行(100),否則 delta 負 → clamp 0 → 無事件。
        let extra = ISO8601.format(Date().addingTimeInterval(-60))
        let line = #"{"timestamp":"\#(extra)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":0,"output_tokens":16,"total_tokens":176}},"rate_limits":{"primary":{"used_percent":11.0,"window_minutes":300,"resets_at":1768475700},"secondary":null,"plan_type":"plus"}}}"#
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: line.appending("\n").data(using: .utf8)!)
        try handle.close()

        let out3 = runRefresh(coordinator)
        XCTAssertEqual(out3.insertedEvents, 1)
        guard let id3 = statIdentity(scanURL) else { return XCTFail("scan-state 消失") }
        XCTAssertTrue(id2.mtimeNs != id3.mtimeNs, "有變動的 tick 必須寫出")
    }

    func testCrossProcessScanStateChangeObservedAndPreserved() throws {
        let dataDir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let (root, rollout) = try writeCodexFixture(input: 200)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanURL = dataDir.appendingPathComponent("scan-state.json")
        let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings(),
                                           adapters: [CodexAdapter(roots: [root])])

        let out1 = runRefresh(coordinator)
        XCTAssertEqual(out1.insertedEvents, 1)
        guard var persisted = try AtomicJSON.readOrThrow([String: ScanState].self, from: scanURL) else {
            return XCTFail("scan-state 未建立")
        }
        guard let markBefore = persisted["codex"]?.files[rollout.path] else {
            return XCTFail("codex mark 未寫入")
        }
        XCTAssertGreaterThan(markBefore.offset, 0)

        // 武裝 oracle(mutation-proof 教訓):寫出會使讀取快取失效,B 動手前必須先跑一個
        // idle tick(skip-write 路徑)讓快取「活著」——否則忽略 fingerprint 的壞實作也讀不到
        // stale 快取,本測試對它空洞。
        let idle = runRefresh(coordinator)
        XCTAssertEqual(idle.insertedEvents, 0)

        // 「行程 B」:重置 codex 的 mark(強迫 A 重掃)並加入一個 A 不認識的 provider 條目。
        persisted["codex"]?.files[rollout.path] = FileScanMark(offset: 0, size: 0)
        persisted["zz-other"] = ScanState(files: ["/fake/b-path": FileScanMark(offset: 123, size: 456)])
        try AtomicJSON.write(persisted, to: scanURL)

        // A 的下一輪:必須看見 B 的 durable 變更(fingerprint 失效 → 重讀),重掃該檔
        //(dedup:不得重複入帳),寫回時不得 clobber B 的外來條目。
        let out2 = runRefresh(coordinator)
        XCTAssertFalse(out2.skipped)
        XCTAssertEqual(out2.insertedEvents, 0, "重掃必須被去重吸收,絕不重複計費")
        guard let after = try AtomicJSON.readOrThrow([String: ScanState].self, from: scanURL) else {
            return XCTFail("scan-state 消失")
        }
        guard let markAfter = after["codex"]?.files[rollout.path] else {
            return XCTFail("codex mark 消失")
        }
        XCTAssertEqual(markAfter.offset, markBefore.offset,
                       "A 必須觀察到 B 的 offset 重置並重掃推進(stale 快取會停在 B 的 0/舊值)")
        XCTAssertEqual(after["zz-other"]?.files["/fake/b-path"]?.offset, 123,
                       "B 的外來條目必須存活(整份磁碟採用 + 合併寫回,不得被 A 的舊視圖 clobber)")
    }

    func testMalformedScanStateStillAbortsRefresh() throws {
        let dataDir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let (root, _) = try writeCodexFixture(input: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanURL = dataDir.appendingPathComponent("scan-state.json")
        let coordinator = UsageCoordinator(dataDir: dataDir, settings: CoreSettings(),
                                           adapters: [CodexAdapter(roots: [root])])
        _ = runRefresh(coordinator)
        _ = runRefresh(coordinator)   // idle tick:武裝讀取快取(同 oracle 測試;否則壞快取讀不到 stale)

        let goodBytes = try Data(contentsOf: scanURL)
        try Data("{{not-json".utf8).write(to: scanURL)   // 存在但解不開(#44 契約 A:必須中止,絕不覆寫)
        let out = runRefresh(coordinator)
        XCTAssertTrue(out.skipped, "malformed scan-state 必須中止本輪寫入(tri-state 經快取路徑原樣保留)")
        XCTAssertEqual(try Data(contentsOf: scanURL), Data("{{not-json".utf8), "中止時不得動 scan-state 檔")

        try goodBytes.write(to: scanURL)   // 復原後照常運作
        let recovered = runRefresh(coordinator)
        XCTAssertFalse(recovered.skipped)
    }
}

// MARK: - B:retention 可觀測性 characterization(production 凍結)

final class RetentionObservabilityCharacterizationTests: XCTestCase {
    func testExpiredEventsRemainObservableUntilPhysicalCompaction() throws {
        let dir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = ISO8601.parse("2026-09-02T00:00:00Z")!
        let ledger = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
        let old = ramEvent("old", "claude-code", at: now.addingTimeInterval(-100 * 86400), input: 100)
        let edge = ramEvent("edge", "claude-code", at: now.addingTimeInterval(-92 * 86400 + 3600), input: 20)
        let fresh = ramEvent("new", "claude-code", at: now.addingTimeInterval(-3600), input: 3)
        XCTAssertEqual(ledger.append([old, edge, fresh]), 3)

        // 特性化事實 1:cutoff 已過、物理壓縮尚未執行 → 無任何 consumer 級 logical filter,
        // 無下限聚合(All-time 等價的 epoch 區間)把過期事件照算;≤90d 顯示面天然構不到。
        // 這就是「compaction 節流」會把 #50 P3『過期貢獻恆 0』與顯示面拆成兩套時間語義的
        // 執行證據(B 的 merge bar 由此而來;見 reviews/ram-p0-2026-09-02/)。
        let allTime = DateInterval(start: Date(timeIntervalSince1970: 0), end: now)
        XCTAssertEqual(ledger.totals(in: allTime).total, 123, "過期未壓縮的事件對 All-time 可見")
        XCTAssertEqual(ledger.dailyBuckets(in: allTime).count, 3)
        // edge(91d23h 前)落在 90d 顯示上限與 92d cutoff 之間的縫隙:Trends 最大 90d 天然
        // 構不到 cutoff 附近 —— 只有 fresh 可見。
        let ninety = DateInterval(start: now.addingTimeInterval(-90 * 86400), end: now)
        XCTAssertEqual(ledger.totals(in: ninety).total, 3, "≤90d 顯示範圍構不到 92d cutoff")

        // 特性化事實 2:物理壓縮是唯一 enforcement —— 壓縮後 All-time 才收斂。
        XCTAssertTrue(ledger.compactWouldAct(retentionDays: 92, now: now))
        let raw = try Data(contentsOf: dir.appendingPathComponent("ledger.jsonl"))
        if case .applied = ledger.compactRawPreserving(retentionDays: 92, now: now, raw: raw) {} else {
            return XCTFail("compact 應 applied")
        }
        XCTAssertEqual(ledger.totals(in: allTime).total, 23)
        XCTAssertEqual(ledger.dailyBuckets(in: allTime).count, 2)
    }

    func testPostCutoffExpiryKeepsHeavyCompactionEligibleEveryMinute() throws {
        // 合成 09-10 之後的常態(不必等真日期):最舊事件剛過 cutoff,其後每分鐘再過期一筆。
        // 特性化:compactWouldAct 在每個相繼分鐘恆真、raw-preserving 每次 .applied 且每次
        // 重讀+重寫全檔 —— 而 coordinator 對它 1:1 掛在每次 refresh(唯一 production 呼叫點
        // 在 UsageCoordinator.refresh 的壓縮塊,無任何時間/批量節流;CompactionLockTests 已證
        // refresh 必經壓縮)。即:節流前,每個 refresh 都是一次全檔重寫級的重操作。
        let dir = ramTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        let now0 = ISO8601.parse("2026-09-10T00:00:00Z")!
        let cutoff0 = now0.addingTimeInterval(-92 * 86400)
        let ledger = UsageLedger(fileURL: ledgerURL)
        var seed: [UsageEvent] = []
        for j in 0..<5 {   // 第 j 筆在 t_j = now0 + j 分鐘時剛好過期
            seed.append(ramEvent("e\(j)", "claude-code",
                                 at: cutoff0.addingTimeInterval(Double(j) * 60 - 1), input: 1))
        }
        seed.append(ramEvent("keep", "claude-code", at: now0.addingTimeInterval(-3600), input: 7))
        XCTAssertEqual(ledger.append(seed), 6)

        for j in 0..<5 {
            let t = now0.addingTimeInterval(Double(j) * 60)
            XCTAssertTrue(ledger.compactWouldAct(retentionDays: 92, now: t),
                          "第 \(j) 分鐘:又有事件過期 → 重壓縮路徑再度合格(無節流 = 每 refresh 都跑)")
            let raw = try Data(contentsOf: ledgerURL)   // 與 coordinator 相同:每次重讀全檔
            if case .applied = ledger.compactRawPreserving(retentionDays: 92, now: t, raw: raw) {} else {
                return XCTFail("第 \(j) 輪 raw-preserving 應 applied")
            }
            XCTAssertEqual(ledger.events.count, 6 - (j + 1), "每輪恰好再移除一筆")
        }
        XCTAssertEqual(ledger.events.count, 1)
        XCTAssertFalse(ledger.compactWouldAct(retentionDays: 92, now: now0.addingTimeInterval(300)))
    }
}
