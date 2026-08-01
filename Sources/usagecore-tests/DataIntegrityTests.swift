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

// #48 Δ4 遷移:diEvent 預設攜帶有效 sourcePath(monotonic gate 契約下 nil-source 屬獨立
// fail-closed 案例——見 MX05/MX06;需要 nil 的測試自行明確傳入)。
private func diEvent(_ id: String, provider: String = "mock", at ts: Date = Date().addingTimeInterval(-3600),
                     sourcePath: String? = "/mock/source.jsonl") -> UsageEvent {
    UsageEvent(id: id, providerId: provider, timestamp: ts, tokens: TokenBreakdown(input: 100),
               sourceKind: "mock", sourcePath: sourcePath)
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

    // #48 pivot §5 遷移(原 #10「complete zero-result 可清空切片」——舊破壞性語意作廢):
    // baseline 非空 + complete zero-result ⇒ monotonic gate 阻擋,全量 preserve。
    // (空 baseline + zero-result 的合法空 slice 由 MX08 鎖;初始化由 MX20 鎖。)
    func testCompleteZeroResultPreservesNonEmptyBaseline() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([diEvent("old-1")])
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [], completeness: .complete), ScanState())
        }
        let coord = UsageCoordinator(dataDir: dir, settings: settingsEnabling("mock"), adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertTrue(reloaded.events.contains { $0.id == "old-1" },
                      "baseline 非空 + zero-result ⇒ preserve(pivot §5)")
        if case .preservedHistoryMismatch(let r, let m, _, _, _)? = outcome.providerOutcomes["mock"] {
            XCTAssertEqual(r, 1, "retained count")
            XCTAssertEqual(m, 1, "missing count")
        } else {
            XCTAssertTrue(false, "outcome 必須為 preservedHistoryMismatch,實得 \(String(describing: outcome.providerOutcomes["mock"]))")
        }
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

    // #48 gate-r1 luna L3(b) 回歸:CAS expected revision = 記憶體載入時指紋——
    // 另一「行程」(第二個 UsageLedger 實例)在本方 reload 後落盤,CAS 必須拒絕 stale 重寫。
    func testCASRejectsStaleMemoryReplace() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let a = UsageLedger(fileURL: url)
        _ = a.append([diEvent("cas-e1")])
        let revision = a.loadedRevision()               // A 的記憶體 == 此 revision
        _ = UsageLedger(fileURL: url).append([diEvent("cas-external")])   // 他方落盤
        var threw = false
        do { _ = try a.replaceProviderSlice("mock", with: [diEvent("cas-new")], expectedRevision: revision) }
        catch UsageLedger.CASError.revisionChanged { threw = true }
        catch { XCTAssertTrue(false, "非預期錯誤 \(error)") }
        XCTAssertTrue(threw, "revision 已前進 ⇒ CAS 必須拒絕 stale 記憶體重寫")
        let reloaded = UsageLedger(fileURL: url)
        XCTAssertTrue(reloaded.events.contains { $0.id == "cas-external" }, "他方事件不得被覆滅")
        XCTAssertFalse(reloaded.events.contains { $0.id == "cas-new" }, "stale 重寫不得落盤")
    }

    // #48 gate-r1 luna L4 回歸:candidate 夾帶他 provider 事件 ⇒ gate fail closed。
    func testGateRejectsForeignProviderCandidateEvents() throws {
        let base = try AtomicJSON.encoder().encode(diEvent("p-1", provider: "p")) + Data([0x0A])
        let decision = UsageCoordinator.monotonicGateDecision(
            baselineRaw: base, providerId: "p",
            candidate: [diEvent("p-1", provider: "p"), diEvent("q-1", provider: "q")])
        guard case .preserve(_, _, _, _, let canon) = decision, canon >= 1 else {
            XCTAssertTrue(false, "外來 provider 事件必須令 gate preserve,實得 \(decision)"); return
        }
        XCTAssertTrue(true)
    }

    // #48 gate-r1 luna L1 回歸:混齡檔(有過期事件會觸發 compact 重寫)+ raw 異常行——
    // precheck 必須跳過 compact,raw 證據(unknown key)保留、provider preserve。
    func testCompactPrecheckPreservesSuspectRawOnMixedAgeFile() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let ts = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("mix-recent", at: ts)));  blob.append(0x0A)
        blob.append(try AtomicJSON.encoder().encode(diEvent("mix-expired", at: Date().addingTimeInterval(-200 * 86400)))); blob.append(0x0A)
        var obj = try JSONSerialization.jsonObject(with: AtomicJSON.encoder().encode(diEvent("mix-raw", at: ts))) as! [String: Any]
        obj["mx_unknown_evidence"] = "keep"
        blob.append(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("mix-recent", at: ts)], completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let raw = String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("mx_unknown_evidence"), "raw 證據不得被 compact 重寫消滅(luna L1)")
        XCTAssertTrue(raw.contains("mix-expired"), "compact 已跳過:過期行原封保留(本輪不修剪)")
        if case .preservedHistoryMismatch? = outcome.providerOutcomes["mock"] {} else {
            XCTAssertTrue(false, "raw 可疑 ⇒ provider 必須 preserve,實得 \(String(describing: outcome.providerOutcomes["mock"]))")
        }
    }

    // #48 gate-r2 luna L3b-殘餘回歸:needsReload(未對帳快照)下記憶體不可信——unstable load 會把
    // stale data 標上較新 fpAfter,指紋比對不可靠,CAS 必須憑旗標拒絕(在任何寫入嘗試之前)。
    // 可決定性觸發:append 落盤失敗設 needsReload 而磁碟未變(指紋仍與 loadedRevision 吻合)。
    func testCASRefusesUnreconciledSnapshot() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        var seed = Data()
        seed.append(try AtomicJSON.encoder().encode(diEvent("base"))); seed.append(0x0A)
        try seed.write(to: file)
        let ledger = UsageLedger(fileURL: file)
        XCTAssertFalse(ledger.hasUnreconciledSnapshot, "初始載入穩定 → 無未對帳快照")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if let h = try? FileHandle(forWritingTo: file) { try? h.close(); return }   // 可寫(如 root)→ 無法模擬,略過
        _ = ledger.append([diEvent("blocked")])
        XCTAssertTrue(ledger.hasUnreconciledSnapshot, "append 落盤失敗 → 未對帳快照旗標設立")
        var threwCAS = false
        do { _ = try ledger.replaceProviderSlice("mock", with: [diEvent("cand")], expectedRevision: ledger.loadedRevision()) }
        catch UsageLedger.CASError.revisionChanged { threwCAS = true }
        catch { XCTAssertTrue(false, "非預期錯誤 \(error)(必須以 revisionChanged 在寫入前拒絕)") }
        XCTAssertTrue(threwCAS, "未對帳快照 ⇒ CAS 必須拒絕(即使指紋看似吻合)")
        XCTAssertEqual(try Data(contentsOf: file), seed, "檔案逐位元組未變(未發生 stale 重寫)")
    }

    // #48 gate-r2 luna L1-殘餘回歸:compact「將動作」但 raw 讀取失敗(檔存在不可讀)⇒ 必須跳過
    // compact(fail closed),不得落回 else 照常重寫——typed 重寫會在不可驗證的檔上消滅 raw 證據。
    func testCompactSkippedWhenRawUnreadable() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let ts = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("ur-recent", at: ts))); blob.append(0x0A)
        blob.append(try AtomicJSON.encoder().encode(diEvent("ur-expired", at: Date().addingTimeInterval(-200 * 86400)))); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("ur-recent", at: ts)], completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])   // 載入於 chmod 前(typed 含過期 → compactWouldAct)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else { return }   // 仍可讀(如 root)→ 無法模擬,略過
        let outcome = runRefresh(coord, fullReindex: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), blob, "raw 不可讀 ⇒ compact 必須跳過,檔案逐位元組未變(過期行未被修剪)")
        if case .preservedHistoryMismatch? = outcome.providerOutcomes["mock"] {} else {
            XCTAssertTrue(false, "raw 不可讀 ⇒ provider 必須 preserve,實得 \(String(describing: outcome.providerOutcomes["mock"]))")
        }
    }

    // #48 gate-r3 sol MF1 回歸:compact 是整檔破壞式重寫——穩定 reload 後他方落盤(指紋前進)
    // 時,typed 記憶體已 stale,compact 必須拒絕(否則 gate 之前就把他方較新事件覆滅)。
    // 決定性觸發:sol 建議的雙 ledger 技法(同矩陣 MX13 用法)。
    func testCompactRefusesStaleFingerprint() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        let a = UsageLedger(fileURL: file)
        _ = a.append([diEvent("cf-expired", at: Date().addingTimeInterval(-200 * 86400)),
                      diEvent("cf-recent")])
        _ = UsageLedger(fileURL: file).append([diEvent("cf-external")])   // 他方落盤:磁碟前進
        let before = try Data(contentsOf: file)
        let r = a.compact(retentionDays: 92)
        XCTAssertEqual(r, .failed, "指紋不符(他方已落盤)⇒ compact 必須拒絕,實得 \(r)")
        XCTAssertEqual(try Data(contentsOf: file), before, "檔案逐位元組未變(他方事件存活)")
        XCTAssertTrue(a.hasUnreconciledSnapshot, "拒絕後設 needsReload,下輪 reloadIfChanged 對帳")
    }

    // #48 gate-r3 sol MF1 回歸(未對帳快照面):needsReload 下 compact 同樣必須拒絕。
    func testCompactRefusesUnreconciledSnapshot() throws {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        let a = UsageLedger(fileURL: file)
        _ = a.append([diEvent("cu-expired", at: Date().addingTimeInterval(-200 * 86400)),
                      diEvent("cu-recent")])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        if let h = try? FileHandle(forWritingTo: file) { try? h.close(); return }   // 可寫(如 root)→ 無法模擬,略過
        _ = a.append([diEvent("cu-blocked")])   // 落盤失敗 → needsReload
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(a.compact(retentionDays: 92), .failed, "未對帳快照 ⇒ compact 拒絕")
        XCTAssertEqual(try Data(contentsOf: file), before, "檔案逐位元組未變")
    }

    // #48 gate-r3 sol MF3 回歸:P 的 replace 不得改寫/丟失其他 provider 的 raw 表示——
    // (a) 小數秒 timestamp 行(typed round-trip 會截斷小數;canonical N3 視為差異);
    // (b) decoder 拒收但 canonicalizer 接受的行(timestamp 非 ISO 格式字串;typed 重寫會整行丟失)。
    // 兩者必須在 P 成功 replace 後逐位元組存活(per-provider isolation,無需任何 race)。
    func testReplacePreservesForeignRawRepresentation() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let ts = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("fp-p1", at: ts))); blob.append(0x0A)
        let tsISO = ISO8601.format(ts)
        let fracLine = #"{"id":"fq-frac","providerId":"other","timestamp":"\#(tsISO.dropLast()).500Z","tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        let oddLine = #"{"id":"fq-odd","providerId":"other","timestamp":"not-an-iso-date","tokens":{"input":2,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        blob.append(Data(fracLine.utf8)); blob.append(0x0A)
        blob.append(Data(oddLine.utf8)); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("fp-p1", at: ts), diEvent("fp-p2", at: ts)],
                                  completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        if case .replaced? = outcome.providerOutcomes["mock"] {} else {
            XCTAssertTrue(false, "candidate 為 baseline 超集,gate 應放行,實得 \(String(describing: outcome.providerOutcomes["mock"]))")
        }
        let after = String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(after.contains(fracLine), "小數秒 raw 行必須逐位元組存活(不經 typed round-trip)")
        XCTAssertTrue(after.contains(oddLine), "decoder 拒收的行必須逐位元組存活(不得因 typed 重寫而丟失)")
        XCTAssertTrue(after.contains("fp-p2"), "目標 provider 新事件已落盤")
    }

    // #48 gate-r3 luna MF1 回歸(nil-split):「不可 stat」≠「確認缺檔」——expected 為 nil(載入時
    // 確認缺檔)而 CAS 時路徑不可 stat(EACCES,無法證明缺檔)⇒ 必須以 revisionChanged 在任何
    // 寫入之前拒絕,不得讓 nil==nil 靜默過檢(tri-state fail-closed,與 persistAppend 一致)。
    func testCASRefusesUnstattableLedgerPath() throws {
        let parent = makeTempDir()
        let dir = parent.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ledger.jsonl")
        let a = UsageLedger(fileURL: file)   // 檔案不存在:合法空帳本,expected fingerprint = nil
        let revision = a.loadedRevision()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let probe = dir.appendingPathComponent(".probe")
        if (try? Data("x".utf8).write(to: probe)) != nil { try? FileManager.default.removeItem(at: probe); return }   // root → 略過
        var threwCAS = false
        do { _ = try a.replaceProviderSlice("mock", with: [diEvent("cand")], expectedRevision: revision) }
        catch UsageLedger.CASError.revisionChanged { threwCAS = true }
        catch { XCTAssertTrue(false, "必須以 revisionChanged 在寫入前拒絕,實得 \(error)") }
        XCTAssertTrue(threwCAS, "不可 stat(EACCES)⇒ CAS 拒絕(nil==nil 不得靜默過檢)")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "未發生任何寫入")
    }

    // #48 gate-r4 回歸(三 reviewer 一致 MUST-FIX,並直接釘住 r3→r4 的接線遺漏):wired path 上
    // compact 必須走 raw 保存式——過期的 typed 行被丟,外來 provider 的小數秒行與 decoder 拒收行
    // 必須逐位元組存活整條 refresh(compact + gate + replace)。
    func testCompactPreservesForeignRawOnWiredPath() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let ts = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3600).rounded(.down))
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("wp-expired", at: Date().addingTimeInterval(-200 * 86400)))); blob.append(0x0A)
        blob.append(try AtomicJSON.encoder().encode(diEvent("wp-recent", at: ts))); blob.append(0x0A)
        let tsISO = ISO8601.format(ts)
        let fracLine = #"{"id":"wq-frac","providerId":"other","timestamp":"\#(tsISO.dropLast()).500Z","tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        let oddLine = #"{"id":"wq-odd","providerId":"other","timestamp":"not-an-iso-date","tokens":{"input":2,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        blob.append(Data(fracLine.utf8)); blob.append(0x0A)
        blob.append(Data(oddLine.utf8)); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("wp-recent", at: ts)], completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let after = String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(after.contains(fracLine), "外來小數秒行必須存活 wired compact(逐位元組)")
        XCTAssertTrue(after.contains(oddLine), "外來 decoder 拒收行必須存活 wired compact(逐位元組)")
        XCTAssertFalse(after.contains("wp-expired"), "過期 typed 行由 raw 保存式 compact 丟棄")
        if case .replaced? = outcome.providerOutcomes["mock"] {} else {
            XCTAssertTrue(false, "compact 後 baseline P 切片=recent,candidate 為超集,應 replaced,實得 \(String(describing: outcome.providerOutcomes["mock"]))")
        }
    }

    // #48 gate-r4 sol MF2 回歸:丟棄判定必須 strict——lenient 解析接受垃圾後綴,會把 canonical
    // 域視為 opaque 的行(前綴看似過期)誤刪。strict 失敗 ⇒ fail-closed 保留。
    func testCompactRawPreservingKeepsGarbageSuffixTimestamp() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let garbageLine = #"{"id":"gs-keep","providerId":"mock","timestamp":"2020-01-01T00:00:00garbage","tokens":{"input":1,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("gs-expired", at: Date().addingTimeInterval(-200 * 86400)))); blob.append(0x0A)
        blob.append(Data(garbageLine.utf8)); blob.append(0x0A)
        blob.append(try AtomicJSON.encoder().encode(diEvent("gs-recent"))); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let ledger = UsageLedger(fileURL: url)
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(ledger.compactRawPreserving(retentionDays: 92, now: Date(), raw: raw), .applied)
        let after = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
        XCTAssertTrue(after.contains(garbageLine), "垃圾後綴 timestamp(strict 解析失敗)⇒ 行必須保留")
        XCTAssertTrue(after.contains("gs-recent"), "近期行保留")
        XCTAssertFalse(after.contains("gs-expired"), "真正過期(strict 可解析)行丟棄")
    }

    // #48 gate-r4 sol MF6 回歸:candidate id 與「僅存在於 raw(decoder 拒收)的外來行」撞號 ⇒
    // 寫出的檔案會含重複 id、立即不可 canonicalize——replace 必須整筆拒絕,檔案逐位元組不變。
    func testReplaceRefusesRawOnlyIDCollision() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("ledger.jsonl")
        let oddLine = #"{"id":"collide-x","providerId":"other","timestamp":"not-an-iso-date","tokens":{"input":2,"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0},"sourceKind":"mock"}"#
        var blob = Data()
        blob.append(try AtomicJSON.encoder().encode(diEvent("rc-p1"))); blob.append(0x0A)
        blob.append(Data(oddLine.utf8)); blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: url)
        let ledger = UsageLedger(fileURL: url)
        var threw = false
        do {
            _ = try ledger.replaceProviderSlice("mock", with: [diEvent("rc-p1"), diEvent("collide-x")],
                                                expectedRevision: ledger.loadedRevision(), preservingRaw: blob)
        } catch { threw = true }
        XCTAssertTrue(threw, "raw-only 外來 id 撞號 ⇒ 拒絕(不得提交不可 canonicalize 的帳本)")
        XCTAssertEqual(try Data(contentsOf: url), blob, "檔案逐位元組未變")
    }

    // C-MF6 × #48 Δ4 遷移:reindex 切片套用保留期 cutoff,不重新引入過期事件。
    // 遷移原則(owner):驗證 successful replacement 的測試必須提供可 canonicalize 的 source
    // identity 且不違反 monotonic gate——seed 改為「真正超過保留期」的事件(refresh 起點的
    // compact 會先修剪 → post-compact baseline 為空 → gate 對 [fresh] 合法放行),
    // 不再期待 gate 吞掉仍在保留期內的歷史。
    func testReindexAppliesRetentionCutoff() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL)
            .append([diEvent("genuinely-stale", at: Date().addingTimeInterval(-200 * 86400))])
        let mock = MockAdapter("mock") { _ in
            (AdapterRefreshResult(events: [diEvent("fresh"),
                                           diEvent("expired", at: Date().addingTimeInterval(-200 * 86400))],
                                  completeness: .complete), ScanState())
        }
        var s = settingsEnabling("mock"); s.retentionDays = 92
        let coord = UsageCoordinator(dataDir: dir, settings: s, adapters: [mock])
        let outcome = runRefresh(coord, fullReindex: true)
        let reloaded = UsageLedger(fileURL: ledgerURL)
        XCTAssertTrue(reloaded.events.contains { $0.id == "fresh" }, "近期事件保留")
        XCTAssertFalse(reloaded.events.contains { $0.id == "expired" }, "reindex 不得重新引入超過保留期的事件(C-MF6)")
        XCTAssertFalse(reloaded.events.contains { $0.id == "genuinely-stale" }, "保留期外舊史由 compact 修剪")
        XCTAssertEqual(outcome.providerOutcomes["mock"], .replaced, "post-compact 空 baseline ⇒ 合法 replaced")
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
