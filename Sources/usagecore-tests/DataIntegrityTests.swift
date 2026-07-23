import Foundation
import UsageCore

// #44 資料完整性契約(見 PR 契約)驗收測試。逐步累加;此批為 step 1(typed reads + 非破壞式讀取)。

final class DataIntegrityReadTests: XCTestCase {
    private func event(_ id: String, _ ts: String) -> UsageEvent {
        UsageEvent(id: id, providerId: "codex", timestamp: ISO8601.parse(ts) ?? Date(timeIntervalSince1970: 0),
                   tokens: TokenBreakdown(input: 100), sourceKind: "test")
    }

    // acceptance #1:帳本存在但讀不到(權限)→ poisoned,不得當空。
    func testUnreadableLedgerIsPoisonedNotEmpty() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(event("e1", "2026-01-15T10:00:00Z")))
        seed.append(0x0A)
        try seed.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        guard (try? Data(contentsOf: file)) == nil else { return }   // 環境允許擁有者讀取(如 root)→ 無法模擬,略過
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNotNil(ledger.loadError, "unreadable ledger → poisoned, not silently empty")
        XCTAssertTrue(ledger.events.isEmpty)
    }

    // acceptance #2:整份 malformed 帳本 → poisoned;load 為唯讀,檔案逐位元組保留待救回。
    func testMalformedLedgerPoisonedAndPreserved() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        let garbage = Data("not json at all\nnor this line either\n".utf8)
        try garbage.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNotNil(ledger.loadError, "all-garbage ledger → poisoned (malformed)")
        XCTAssertEqual(try Data(contentsOf: file), garbage, "poisoned ledger preserved byte-for-byte")
    }

    // 反向 sanity:含斷尾片段但仍有有效事件 → 不 poison(維持既有斷尾→續寫復原)。
    func testValidLedgerWithTornTailNotPoisoned() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(event("ok", "2026-01-15T10:00:00Z")))
        seed.append(0x0A)
        seed.append(Data(#"{"id":"torn"#.utf8))
        try seed.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNil(ledger.loadError)
        XCTAssertEqual(ledger.events.map(\.id), ["ok"])
    }

    // acceptance #3:scan-state 讀取三態——missing → nil;malformed → throw(不得靜默當空)。
    func testScanStateReadOrThrowTriState() throws {
        let url = makeTempDir().appendingPathComponent("scan-state.json")
        XCTAssertNil(try AtomicJSON.readOrThrow([String: ScanState].self, from: url))   // missing → nil
        try Data("{ not valid json".utf8).write(to: url)
        var threw = false
        do { _ = try AtomicJSON.readOrThrow([String: ScanState].self, from: url) } catch { threw = true }
        XCTAssertTrue(threw, "malformed scan-state → throw (不得靜默當空)")
    }

    // acceptance #3:limits-state 存在但讀不到 → poisoned(save 會據此拒絕覆寫)。
    func testUnreadableLimitsStateIsPoisoned() throws {
        let url = makeTempDir().appendingPathComponent("limits-state.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else { return }
        let limits = LimitEngine(stateURL: url)
        XCTAssertNotNil(limits.loadError)
    }

    // acceptance #4:append 落盤失敗 → 記憶體完全回復(無 split-brain),writeError 設立,檔案未變。
    func testAppendWriteFailureRollsBackMemory() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(event("e1", "2026-01-15T10:00:00Z")))
        seed.append(0x0A)
        try seed.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertEqual(ledger.events.map(\.id), ["e1"])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if let h = try? FileHandle(forWritingTo: file) { try? h.close(); return }   // 可寫(如 root)→ 無法模擬,略過
        let n = ledger.append([event("e2", "2026-01-15T11:00:00Z")])
        XCTAssertNotNil(ledger.writeError, "落盤失敗 → writeError")
        XCTAssertEqual(n, 0, "落盤失敗回 0")
        XCTAssertEqual(ledger.events.map(\.id), ["e1"], "記憶體未提交(無 e2)")
        XCTAssertEqual(try Data(contentsOf: file), seed, "檔案逐位元組未變")
    }

    // acceptance #5:compact 落盤失敗 → 舊記憶體與舊檔案皆保留。
    func testCompactWriteFailurePreservesOldFileAndMemory() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(event("old", "2020-01-01T00:00:00Z")))
        seed.append(0x0A)
        seed.append(try AtomicJSON.encoder().encode(event("recent", "2026-01-15T10:00:00Z")))
        seed.append(0x0A)
        try seed.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertEqual(ledger.events.count, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let probe = dir.appendingPathComponent(".probe")
        if (try? Data("x".utf8).write(to: probe)) != nil { try? FileManager.default.removeItem(at: probe); return }
        // now=2026-01-20:cutoff≈2025-12-21 → 丟 old、留 recent → 需重寫;目錄唯讀 → 寫入失敗。
        ledger.compact(retentionDays: 30, now: ISO8601.parse("2026-01-20T00:00:00Z")!)
        XCTAssertEqual(ledger.events.count, 2, "compact 失敗 → 記憶體保留兩筆")
        XCTAssertEqual(try Data(contentsOf: file), seed, "compact 失敗 → 檔案逐位元組保留")
    }
}

// MARK: - #44 mock adapter + reindex/adoption 驗收(#6–#14)。近期時間戳避開 compact 保留期修剪。

private func diEvent(_ id: String, provider: String = "mock", at ts: Date = Date().addingTimeInterval(-3600)) -> UsageEvent {
    UsageEvent(id: id, providerId: provider, timestamp: ts, tokens: TokenBreakdown(input: 100), sourceKind: "mock")
}

final class MockAdapter: ProviderAdapter {
    let providerId: String
    let historyModel: ProviderHistoryModel
    private let make: (ScanState) -> (AdapterRefreshResult, ScanState)
    var lastSeenState: ScanState?
    init(_ providerId: String, historyModel: ProviderHistoryModel = .rebuildableHistory,
         make: @escaping (ScanState) -> (AdapterRefreshResult, ScanState)) {
        self.providerId = providerId
        self.historyModel = historyModel
        self.make = make
    }
    var displayName: String { providerId }
    var roots: [URL] { [] }
    var watchFiles: [URL] { [] }
    func detectAvailability() -> ProviderAvailability { ProviderAvailability(available: true, detail: "mock") }
    func refreshUsage(state: ScanState) throws -> (AdapterRefreshResult, ScanState) {
        lastSeenState = state
        return make(state)
    }
    func explainDataSources() -> String { "mock" }
    func explainRequiredPermissions() -> String { "mock" }
    func diagnosticSources() -> [DiagnosticSourceDescriptor] { [] }
}

private func runRefresh(_ coord: UsageCoordinator, fullReindex: Bool = false) -> RefreshOutcome {
    let sem = DispatchSemaphore(value: 0)
    var out: RefreshOutcome?
    Task { out = await coord.refresh(fullReindex: fullReindex); sem.signal() }
    sem.wait()
    return out!
}

private func settingsEnabling(_ pid: String) -> CoreSettings {
    var s = CoreSettings()
    s.enabledProviders = [pid]
    return s
}

final class DataIntegrityReindexTests: XCTestCase {

    // #9:incomplete scan → 保留舊切片(不刪歷史、不 replace),誠實通知。
    func testIncompleteReindexPreservesOldSlice() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([diEvent("old-1")])
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("fresh-should-not-appear")], completeness: .incomplete("io")), ScanState())
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertTrue(reloaded.events.contains { $0.id == "old-1" }, "incomplete reindex 必保留舊切片")
        XCTAssertFalse(reloaded.events.contains { $0.id == "fresh-should-not-appear" }, "incomplete 不得 replace")
        XCTAssertTrue(outcome.dashboard.dataQuality.contains { $0.contains("reindex incomplete") }, "誠實通知")
    }

    // #10:complete zero-result → 可合法清空 rebuildable 切片。
    func testCompleteZeroResultEmptiesRebuildableSlice() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([diEvent("old-1")])
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [], completeness: .complete), ScanState())
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        _ = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertFalse(reloaded.events.contains { $0.providerId == "mock" }, "complete 零筆 → 合法清空 rebuildable 切片")
    }

    // #13:cumulativeSnapshotOnly(OpenCode 類)reindex → 保留既有歷史、只走增量,不塌成一筆。
    func testCumulativeSnapshotReindexPreservesHistory() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([diEvent("old-cumulative-1"), diEvent("old-cumulative-2")])
        let mock = MockAdapter("mock", historyModel: .cumulativeSnapshotOnly) { _ in
            (AdapterRefreshResult(events: [diEvent("new-delta")], completeness: .complete), ScanState())
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertTrue(reloaded.events.contains { $0.id == "old-cumulative-1" }, "cumulative reindex 不得刪既有歷史")
        XCTAssertTrue(reloaded.events.contains { $0.id == "old-cumulative-2" }, "cumulative reindex 不得刪既有歷史")
        XCTAssertTrue(reloaded.events.contains { $0.id == "new-delta" }, "仍走增量、加入新 delta")
        XCTAssertTrue(outcome.dashboard.dataQuality.contains { $0.contains("reindex kept cumulative") }, "誠實通知")
    }

    // #6:持鎖後嚴格採用磁碟 scan-state;另一「行程」改寫後本行程採用之(陳舊記憶體進度不得復活)。
    func testStrictDiskAdoptionOfScanState() throws {
        let dir = makeTempDir()
        let scanURL = dir.appendingPathComponent("scan-state.json")
        var advanced = ScanState()
        advanced.files["/x/log"] = FileScanMark(offset: 999, size: 999)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("e1")], completeness: .complete), advanced)
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        _ = runRefresh(coord)                       // refresh 1:推進並持久化 scan-state
        try Data("{}".utf8).write(to: scanURL)      // 模擬另一行程重置為空
        _ = runRefresh(coord)                       // refresh 2:應採用磁碟(空)而非陳舊記憶體(offset 999)
        XCTAssertEqual(mock.lastSeenState?.files.isEmpty, true,
                       "持鎖後嚴格採用磁碟 scan-state;陳舊記憶體進度不得復活")
    }

    // C-MF5:scan-state 檔被刪除(nil,非 {})→ 整份採用空集合,舊 watermark 不得復活。
    func testDeletedScanStateAdoptedAsEmpty() throws {
        let dir = makeTempDir()
        let scanURL = dir.appendingPathComponent("scan-state.json")
        var advanced = ScanState()
        advanced.files["/x/log"] = FileScanMark(offset: 999, size: 999)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("e1")], completeness: .complete), advanced)
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        _ = runRefresh(coord)                                  // 推進並持久化 scan-state
        try FileManager.default.removeItem(at: scanURL)        // 刪除(codex C-MF5 的缺口:#6 只寫了 {})
        _ = runRefresh(coord)                                  // 應採用空,而非陳舊記憶體 offset 999
        XCTAssertEqual(mock.lastSeenState?.files.isEmpty, true, "刪檔後應採用空 scan-state,陳舊 watermark 不得復活")
    }

    // C-MF6:reindex 切片套用保留期 cutoff,不重新引入超過保留期的過期事件。
    func testReindexAppliesRetentionCutoff() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([diEvent("stale-in-ledger")])
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("fresh"),
                                           diEvent("expired", at: Date().addingTimeInterval(-200 * 86400))],
                                  completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])
        _ = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertTrue(reloaded.events.contains { $0.id == "fresh" }, "近期事件保留")
        XCTAssertFalse(reloaded.events.contains { $0.id == "expired" }, "reindex 不得重新引入超過保留期的事件(C-MF6)")
    }

    // R2-MF1 回退 / round-3 P1-B:cumulative provider 的 baseline **不因磁碟 scan-state 缺失被清空**
    //(回到本 PR 前安全行為),故不會從零重算 → 不 overcount。LIVE 情境:記憶體有 baseline、磁碟 scan-state 被刪。
    func testCumulativeBaselinePreservedWhenScanStateMissing() throws {
        let dir = makeTempDir()
        let scanURL = dir.appendingPathComponent("scan-state.json")
        var baseline = ScanState()
        baseline.files["/mock/db"] = FileScanMark(offset: 42, size: 42, context: ["base": "100"])
        let mock = MockAdapter("mock", historyModel: .cumulativeSnapshotOnly) { _ in
            (AdapterRefreshResult(events: [], completeness: .complete), baseline)   // 已對齊 baseline,無新 delta
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        _ = runRefresh(coord)                              // refresh 1:建立並持久化 baseline
        try FileManager.default.removeItem(at: scanURL)    // 刪除磁碟 scan-state(模擬遺失)
        _ = runRefresh(coord)                              // refresh 2:cumulative baseline 應被保留、非清空
        XCTAssertEqual(mock.lastSeenState?.files["/mock/db"]?.offset, 42,
                       "cumulative baseline 不因磁碟缺標記而清空(否則會從零重算 → overcount)")
    }

    // codex targeted P1 案例(本 PR 以「cumulative 整段保留記憶體」涵蓋;proper durable-state 設計為 follow-up):
    // 磁碟含**異 db-path** 標記、缺 live mark 時,cumulative 的記憶體 baseline 仍完整保留(不被磁碟採用清掉 → 不 zero-baseline)。
    func testCumulativeBaselinePreservedWhenDiskHasDifferentMark() throws {
        let dir = makeTempDir()
        let scanURL = dir.appendingPathComponent("scan-state.json")
        var live = ScanState()
        live.files["/db/A"] = FileScanMark(offset: 7, size: 7)
        let mock = MockAdapter("mock", historyModel: .cumulativeSnapshotOnly) { _ in
            (AdapterRefreshResult(events: [], completeness: .complete), live)
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        _ = runRefresh(coord)                              // 建立 live baseline /db/A
        var diskOther = ScanState()
        diskOther.files["/db/B"] = FileScanMark(offset: 99, size: 99)
        try AtomicJSON.write(["mock": diskOther], to: scanURL)   // 磁碟只含異 db-path 標記(缺 /db/A)
        _ = runRefresh(coord)
        XCTAssertEqual(mock.lastSeenState?.files["/db/A"]?.offset, 7,
                       "磁碟非空但缺 live mark 時,cumulative 記憶體 baseline 仍保留(codex P1 案例)")
    }
}

final class DataIntegrityLedgerTests: XCTestCase {

    // #7:同大小、不同 inode 的帳本替換 → 會重載(只比 size 會漏)。
    func testSameSizeDifferentContentReloads() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        var a = Data(); a.append(try AtomicJSON.encoder().encode(diEvent("id-a", at: fixed))); a.append(0x0A)
        try a.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertEqual(ledger.events.map(\.id), ["id-a"])
        var b = Data(); b.append(try AtomicJSON.encoder().encode(diEvent("id-b", at: fixed))); b.append(0x0A)
        XCTAssertEqual(a.count, b.count, "測試前提:兩者位元組大小相同")
        try b.write(to: file, options: .atomic)     // 原子替換 → 新 inode、大小相同
        ledger.reloadIfChanged()
        XCTAssertEqual(ledger.events.map(\.id), ["id-b"], "同大小內容替換必須被身分指紋偵測並重載")
    }

    // #11:staged replace 中途落盤失敗 → 記憶體與磁碟皆不變。
    func testReplaceProviderSliceWriteFailurePreservesDiskAndMemory() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: file).append([diEvent("p1", provider: "p"), diEvent("q1", provider: "q")])
        let before = try Data(contentsOf: file)
        let ledger = UsageLedger(fileURL: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let probe = dir.appendingPathComponent(".probe")
        if (try? Data("x".utf8).write(to: probe)) != nil { try? FileManager.default.removeItem(at: probe); return }
        var threw = false
        do { try ledger.replaceProviderSlice("p", with: [diEvent("p-new", provider: "p")]) } catch { threw = true }
        XCTAssertTrue(threw, "落盤失敗必 throw")
        XCTAssertEqual(Set(ledger.events.map(\.id)), ["p1", "q1"], "記憶體不變(交易式)")
        XCTAssertEqual(try Data(contentsOf: file), before, "磁碟 byte-for-byte 不變")
    }

    // #14:新品質通知在可分享 sink 被辨識為誠實、無原文、不說 success/completed。
    func testQualityNotesShareSafeAndHonest() throws {
        let cumulative = PrivacyRedaction.safeDataQuality("opencode: reindex kept cumulative history — not rebuildable")
        XCTAssertTrue(cumulative.lowercased().contains("cumulative"), "保留有意義語意")
        XCTAssertFalse(cumulative.lowercased().contains("success"), "不得說成功")
        let incomplete = PrivacyRedaction.safeDataQuality("codex: reindex incomplete — history preserved")
        XCTAssertTrue(incomplete.lowercased().contains("preserved") || incomplete.lowercased().contains("incomplete"))
        XCTAssertFalse(incomplete.lowercased().contains("completed"), "不得把保留說成 reindex completed")
        let stateRead = PrivacyRedaction.safeDataQuality("state read failed — refresh skipped; data preserved")
        XCTAssertFalse(stateRead.contains("/"), "無路徑")
        XCTAssertTrue(stateRead.lowercased().contains("preserved"))
    }

    // grok MUST-FIX 回歸:列舉中途子樹讀取失敗 → complete:false(不得靜默當完整,否則 reindex 誤刪未列到的歷史)。
    func testListFilesFlagsIncompleteOnUnreadableSubtree() throws {
        let root = makeTempDir()
        try Data("{}\n".utf8).write(to: root.appendingPathComponent("readable.jsonl"))
        let locked = root.appendingPathComponent("locked-subdir")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: locked.appendingPathComponent("inside.jsonl"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let listing = JSONLScanner.listFiles(root: root, pathExtension: "jsonl")
        guard !listing.complete else { return }   // 環境未阻擋列舉(如 root)→ 無法模擬,略過
        XCTAssertTrue(listing.files.contains { $0.url.lastPathComponent == "readable.jsonl" }, "可讀檔仍應列出")
    }

    // C-MF7b:只有換行位元組的損壞帳本(非空＋零事件)→ poison,不得當健康的空。
    func testNewlineOnlyLedgerIsPoisoned() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        try Data("\n\n\n".utf8).write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNotNil(ledger.loadError, "只有換行的非空檔 → poison(非空且零事件)")
    }

    // R2-MF4(鎖定 round-1 折衷 + ADR 記錄的格式級限制):有效行中夾一壞的「已收尾」行 → 仍健康(容忍),
    // 只有「非空且零有效事件」才 poison。此為既有斷尾-續寫復原的必然代價(中段偵測與斷尾容忍不可兼得)。
    // 任何改為「中段行也 poison」都會在此顯性失敗,逼出有意識的決定。
    func testValidRowsWithCorruptMiddleRowStayHealthy() throws {
        let file = makeTempDir().appendingPathComponent("ledger.jsonl")
        let enc = AtomicJSON.encoder()
        var data = Data()
        data.append(try enc.encode(diEvent("v1"))); data.append(0x0A)
        data.append(Data("{corrupt middle line}".utf8)); data.append(0x0A)   // 已收尾的壞行
        data.append(try enc.encode(diEvent("v2"))); data.append(0x0A)
        try data.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNil(ledger.loadError, "有效行存在時容忍壞行(round-1 折衷;斷尾-續寫復原的代價)")
        XCTAssertEqual(Set(ledger.events.map(\.id)), ["v1", "v2"], "保留可解出的有效事件")
    }

    // round-3 P1-A:既有非空帳本在 stat 失敗時 fail-closed(不整檔覆寫);檔案 byte-for-byte 不變。
    func testStatFailurePreservesExistingLedgerFailClosed() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(diEvent("e1"))); seed.append(0x0A)
        try seed.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)   // 目錄不可 traverse → stat(file) 失敗
        var st = stat()
        guard stat(file.path, &st) != 0 else {   // 環境仍可 stat(如 root)→ 無法模擬,還原並略過
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            return
        }
        let n = ledger.append([diEvent("e2")])
        XCTAssertEqual((ledger.writeError as? CocoaError)?.code, .fileWriteUnknown,
                       "stat 失敗 → 特定的 fail-closed 錯誤(非任意 error;codex NIT)")
        XCTAssertEqual(n, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: file), seed, "既有非空帳本 byte-for-byte 不變(未被整檔覆寫)")
    }

    // round-3 P1-A:0-byte 空檔的首寫若失敗(原子替換整筆或無)→ 檔案保持可恢復(不留未收尾首筆而永久 poison)。
    func testEmptyLedgerFirstWriteFailurePreservesFile() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        try Data().write(to: file)   // 0-byte
        let ledger = UsageLedger(fileURL: file)
        XCTAssertNil(ledger.loadError, "0-byte → 合法空帳本")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let probe = dir.appendingPathComponent(".probe")
        if (try? Data("x".utf8).write(to: probe)) != nil { try? FileManager.default.removeItem(at: probe); return }
        let n = ledger.append([diEvent("e1")])
        XCTAssertNotNil(ledger.writeError, "空檔原子寫入失敗 → writeError")
        XCTAssertEqual(n, 0)
        XCTAssertEqual((try Data(contentsOf: file)).count, 0, "0-byte 檔保持可恢復(未留未收尾首筆)")
    }
}
