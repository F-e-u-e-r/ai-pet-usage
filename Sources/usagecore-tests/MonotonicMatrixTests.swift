import Foundation
import UsageCore

// #48 Option C binding matrix(pivot:issue #48 comment 5120184667 §6)。
// 這是 SPEC 測試:斷言「ledger-authoritative monotonic compare-and-replace gate」的契約行為。
// 現行實作尚無此 gate,因此依 mapping 文件預期 12 案例紅燈(MX01–05,07,11–16)、6 案例綠燈
// (MX06,08,09,10,17,18)——紅燈是本輪的證明目標,不得為轉綠而弱化斷言(gate 變更屬 owner)。
// 比較 oracle 為「測試側最小版」:直接比 UsageEvent 欄位 + MX15 檢查 raw JSONL key;
// 刻意不是 production canonicalizer(後者於下一階段依契約 §2 另行實作與驗收)。
// 預期 outcome 詞彙(preserved-history-mismatch 等)之 production enum 尚不存在;
// 本輪只斷言 ledger 層行為(preserve / replace / 不留 partial)。

// MARK: - 本檔專用 helpers(既有 diEvent/runRefresh 為 DataIntegrityTests 私有,此處自帶)

/// 整秒、落在 retention(預設 92 天)內的時間戳——避免 ISO8601 round-trip 掉小數秒造成假差異。
private func mxTS(_ offsetSeconds: TimeInterval = -3600) -> Date {
    Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + offsetSeconds).rounded(.down))
}

private func mxEvent(_ id: String, provider: String = "mx", at ts: Date = mxTS(),
                     model: String? = nil, sourcePath: String? = "/mx/source-a.jsonl",
                     tokens: TokenBreakdown = TokenBreakdown(input: 100)) -> UsageEvent {
    UsageEvent(id: id, providerId: provider, modelId: model, timestamp: ts,
               tokens: tokens, sourceKind: "mx", sourcePath: sourcePath)
}

private func mxSettings(_ pids: [String]) -> CoreSettings {
    var s = CoreSettings()
    s.enabledProviders = Set(pids)
    return s
}

private func mxRun(_ coord: UsageCoordinator, fullReindex: Bool) -> RefreshOutcome {
    let sem = DispatchSemaphore(value: 0)
    var out: RefreshOutcome?
    Task { out = await coord.refresh(fullReindex: fullReindex); sem.signal() }
    sem.wait()
    return out!
}

private func mxReload(_ dir: URL) -> [UsageEvent] {
    UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).events
}

/// 測試側最小 canonical 欄位比較(非 production canonicalizer):
/// id/provider/timestamp/tokens 全六欄/sourceKind/sourcePath/modelId/account/project/providerCostUSD 全等。
private func mxSamePayload(_ a: UsageEvent, _ b: UsageEvent) -> Bool {
    a.id == b.id && a.providerId == b.providerId && a.timestamp == b.timestamp
        && a.tokens.input == b.tokens.input && a.tokens.output == b.tokens.output
        && a.tokens.cacheRead == b.tokens.cacheRead
        && a.tokens.cacheWrite5m == b.tokens.cacheWrite5m
        && a.tokens.cacheWrite1h == b.tokens.cacheWrite1h
        && a.tokens.cacheWriteUnknown == b.tokens.cacheWriteUnknown
        && a.sourceKind == b.sourceKind && a.sourcePath == b.sourcePath && a.modelId == b.modelId
        && a.accountId == b.accountId && a.projectId == b.projectId
        && a.projectName == b.projectName && a.providerCostUSD == b.providerCostUSD
}

/// raw JSONL 層的 ID 出現次數(繞過 UsageLedger 載入時的 keep-first 去重,
/// 讓「恰好一筆」斷言能抓到未來實作把重複行寫上磁碟的情況)。
private func mxRawIDCount(_ dir: URL, _ id: String) -> Int {
    let raw = (try? String(contentsOf: dir.appendingPathComponent("ledger.jsonl"), encoding: .utf8)) ?? ""
    return raw.components(separatedBy: "\"id\":\"\(id)\"").count - 1
}

private func mxComplete(_ events: [UsageEvent]) -> (AdapterRefreshResult, ScanState) {
    (AdapterRefreshResult(events: events, completeness: .complete), ScanState())
}

// MARK: - 18 案例矩陣

final class MonotonicMatrixTests: XCTestCase {

    // MX01:candidate 缺歷史 event → preserve(現行:replace 丟史 → 預期紅)。
    func testMX01_candidateMissingHistoricalEvent_preserves() throws {
        let dir = makeTempDir()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-e1"), mxEvent("mx-e2")])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-e1")]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-e1"), "MX01 既有 e1 必須存在")
        XCTAssertTrue(ids.contains("mx-e2"), "MX01 candidate 缺 e2 ⇒ 契約要求 preserve;e2 不得消失")
    }

    // MX02:同 source 乾淨截斷後直接 reindex → preserve(預期紅)。
    func testMX02_cleanTruncationDirectReindex_preserves() throws {
        let dir = makeTempDir()
        let s = "/mx/session-s1.jsonl"
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-s1e1", sourcePath: s), mxEvent("mx-s1e2", sourcePath: s)])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-s1e1", sourcePath: s)]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-s1e1"), "MX02 head 事件存在")
        XCTAssertTrue(ids.contains("mx-s1e2"), "MX02 截斷尾段 ⇒ preserve;tail 事件不得消失")
    }

    // MX03:截斷 → 先 incremental refresh(append 不刪史)→ 再 reindex → preserve(reindex 段預期紅)。
    func testMX03_truncationThenIncrementalThenReindex_preserves() throws {
        let dir = makeTempDir()
        let s = "/mx/session-s1.jsonl"
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-s1e1", sourcePath: s), mxEvent("mx-s1e2", sourcePath: s)])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-s1e1", sourcePath: s)]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: false)   // 截斷後的 incremental:keep-first append,不得刪史
        var ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-s1e2"), "MX03 incremental append 階段不得刪除歷史")
        _ = mxRun(coord, fullReindex: true)    // 中間 refresh 後的 reindex 仍須 preserve
        ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-s1e1"), "MX03 head 事件存在")
        XCTAssertTrue(ids.contains("mx-s1e2"), "MX03 truncation→incremental→reindex ⇒ preserve;tail 不得消失")
    }

    // MX04:scan-state 遺失後 reindex,candidate 缺史 → preserve(gate 是 ledger-authoritative;預期紅)。
    func testMX04_scanStateLossThenReindex_preserves() throws {
        let dir = makeTempDir()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-e1"), mxEvent("mx-e2")])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-e1")]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: false)   // 先讓 scan-state 落地
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("scan-state.json"))
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-e2"), "MX04 scan-state 遺失不影響 gate;candidate 缺 e2 ⇒ preserve")
    }

    // MX05:baseline 含 sourcePath=nil 事件,candidate 缺它 → preserve(預期紅)。
    func testMX05_nilSourcePathBaselineCandidateMissing_preserves() throws {
        let dir = makeTempDir()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-nil", sourcePath: nil), mxEvent("mx-e1")])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-e1")]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mx-nil"), "MX05 nil-source 歷史事件 ⇒ candidate 缺它必須 preserve")
    }

    // MX06:baseline nil-source 事件,candidate 含相同 ID + 完全相容 payload → 通過 history gate(預期綠)。
    func testMX06_nilSourcePathIdenticalCandidate_passesGate() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        let base = mxEvent("mx-nil", at: ts, sourcePath: nil)
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).append([base])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-nil", at: ts, sourcePath: nil)]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let got = mxReload(dir).filter { $0.id == "mx-nil" }
        XCTAssertEqual(got.count, 1, "MX06 相同 ID 恰好一筆")
        XCTAssertEqual(mxRawIDCount(dir, "mx-nil"), 1, "MX06 raw 層亦恰好一行(不受載入去重遮蔽)")
        XCTAssertTrue(got.first.map { mxSamePayload($0, base) } ?? false, "MX06 payload 完全相容 ⇒ 可通過 gate")
    }

    // MX07:complete zero-result 而 baseline 非空 → preserve(pivot §5 收窄舊語意;預期紅)。
    func testMX07_completeZeroResultNonEmptyBaseline_preserves() throws {
        let dir = makeTempDir()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).append([mxEvent("mx-e1")])
        let mock = MockAdapter("mx") { _ in mxComplete([]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        XCTAssertTrue(mxReload(dir).contains { $0.id == "mx-e1" },
                      "MX07 baseline 非空 + zero-result ⇒ preserve,不得清空")
    }

    // MX08:complete zero-result 且 baseline 為空 → 維持空 slice(預期綠)。
    func testMX08_completeZeroResultEmptyBaseline_staysEmpty() throws {
        let dir = makeTempDir()
        let mock = MockAdapter("mx") { _ in mxComplete([]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        XCTAssertTrue(mxReload(dir).filter { $0.providerId == "mx" }.isEmpty,
                      "MX08 空 baseline + zero-result ⇒ 空 slice 合法")
    }

    // MX09:candidate ⊇ baseline 且含新事件 → replacement 成功(預期綠)。
    // 時間戳兩側同值釘死(reviewer F1):closure 於 refresh 中途執行,重算 mxTS() 跨秒時
    // 會把本案例意外變成 MX11b 的 timestamp-change 情境,令未來正確 gate 間歇性 preserve。
    func testMX09_supersetWithNewEvents_replaces() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-e1", at: ts), mxEvent("mx-e2", at: ts)])
        let mock = MockAdapter("mx") { _ in
            mxComplete([mxEvent("mx-e1", at: ts), mxEvent("mx-e2", at: ts), mxEvent("mx-e3", at: ts)])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let ids = mxReload(dir).map(\.id)
        for want in ["mx-e1", "mx-e2", "mx-e3"] {
            XCTAssertEqual(ids.filter { $0 == want }.count, 1, "MX09 \(want) 恰好一筆")
            XCTAssertEqual(mxRawIDCount(dir, want), 1, "MX09 \(want) raw 層亦恰好一行")
        }
    }

    // MX10:allowlisted 單調 enrichment(model nil→known)→ replacement 成功(預期綠)。
    func testMX10_allowlistedModelEnrichment_replaces() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-e1", at: ts, model: nil)])
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-e1", at: ts, model: "m-known")]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let got = mxReload(dir).filter { $0.id == "mx-e1" }
        XCTAssertEqual(got.count, 1, "MX10 恰好一筆")
        XCTAssertEqual(mxRawIDCount(dir, "mx-e1"), 1, "MX10 raw 層亦恰好一行")
        XCTAssertEqual(got.first?.modelId, "m-known", "MX10 nil→known enrichment 生效")
        XCTAssertEqual(got.first?.tokens.input, 100, "MX10 token 不變")
        XCTAssertEqual(got.first?.timestamp, ts, "MX10 timestamp 不變")
    }

    // MX11:非單調變更(token / timestamp / known→known model)→ preserve ×3(預期紅 ×3)。
    func testMX11_nonMonotonicChanges_preserve() throws {
        // 變體 a:token 變更
        do {
            let dir = makeTempDir("MX11a")
            let ts = mxTS()
            _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
                .append([mxEvent("mx-a", at: ts, tokens: TokenBreakdown(input: 100))])
            let mock = MockAdapter("mx") { _ in
                mxComplete([mxEvent("mx-a", at: ts, tokens: TokenBreakdown(input: 999))])
            }
            let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
            _ = mxRun(coord, fullReindex: true)
            XCTAssertEqual(mxReload(dir).first { $0.id == "mx-a" }?.tokens.input, 100,
                           "MX11a token 變更 ⇒ preserve 原值")
        }
        // 變體 b:timestamp 變更
        do {
            let dir = makeTempDir("MX11b")
            let t0 = mxTS(-7200), t1 = mxTS(-3600)
            _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
                .append([mxEvent("mx-b", at: t0)])
            let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-b", at: t1)]) }
            let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
            _ = mxRun(coord, fullReindex: true)
            XCTAssertEqual(mxReload(dir).first { $0.id == "mx-b" }?.timestamp, t0,
                           "MX11b timestamp 變更 ⇒ preserve 原值")
        }
        // 變體 c:known→known model 變更
        do {
            let dir = makeTempDir("MX11c")
            let ts = mxTS()
            _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
                .append([mxEvent("mx-c", at: ts, model: "m-one")])
            let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-c", at: ts, model: "m-two")]) }
            let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
            _ = mxRun(coord, fullReindex: true)
            XCTAssertEqual(mxReload(dir).first { $0.id == "mx-c" }?.modelId, "m-one",
                           "MX11c known→known model ⇒ preserve 原值")
        }
    }

    // MX12:candidate 內部 duplicate event ID → 歧義 ⇒ preserve(現行靜默 keep-first 去重;預期紅)。
    func testMX12_duplicateCandidateIDs_preserves() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-dup", at: ts, tokens: TokenBreakdown(input: 100))])
        let mock = MockAdapter("mx") { _ in
            mxComplete([mxEvent("mx-dup", at: ts, tokens: TokenBreakdown(input: 999)),
                        mxEvent("mx-dup", at: ts, tokens: TokenBreakdown(input: 888))])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        XCTAssertEqual(mxReload(dir).first { $0.id == "mx-dup" }?.tokens.input, 100,
                       "MX12 duplicate ID 歧義 ⇒ fail closed;baseline payload 不得被任一重複版本取代")
    }

    // MX13:stale-baseline race——scan 期間另一「行程」直接 append eNew(閉包內同步 hook,零 timing 依賴)。
    // 契約:final-lock 內 re-read 比對,eNew 不得被 stale replacement 覆滅(預期紅)。
    func testMX13_staleBaselineRace_noStaleOverwrite() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        _ = UsageLedger(fileURL: ledgerURL).append([mxEvent("mx-e1")])
        let mock = MockAdapter("mx") { _ in
            // 模擬並發 CLI/GUI:於 candidate 建立期間,第二個 UsageLedger 實例直接落盤新事件。
            _ = UsageLedger(fileURL: ledgerURL).append([mxEvent("mx-new-during-scan")])
            return mxComplete([mxEvent("mx-e1")])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        XCTAssertTrue(mxReload(dir).contains { $0.id == "mx-new-during-scan" },
                      "MX13 比對後才落盤的並發事件不得被 stale replacement 覆寫")
    }

    // MX14:per-provider isolation——P mismatch preserve、Q superset 照常 replace(P 側預期紅)。
    // 時間戳兩側同值釘死(reviewer F1,同 MX09)。
    func testMX14_providerIsolation_mismatchDoesNotBlockOther() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mxp-1", provider: "mxp", at: ts), mxEvent("mxp-2", provider: "mxp", at: ts),
                     mxEvent("mxq-1", provider: "mxq", at: ts)])
        let p = MockAdapter("mxp") { _ in mxComplete([mxEvent("mxp-1", provider: "mxp", at: ts)]) }
        let q = MockAdapter("mxq") { _ in
            mxComplete([mxEvent("mxq-1", provider: "mxq", at: ts), mxEvent("mxq-2", provider: "mxq", at: ts)])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mxp", "mxq"]), adapters: [p, q])
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        XCTAssertTrue(ids.contains("mxp-2"), "MX14 P mismatch ⇒ P slice preserve")
        XCTAssertTrue(ids.contains("mxq-1") && ids.contains("mxq-2"),
                      "MX14 Q 通過 gate ⇒ 獨立 replace 不受 P 影響")
    }

    // MX15:raw ledger 行含未知欄位——unknown-field 差異 ⇒ fail closed,原始 bytes 的 key 不得被吞(預期紅)。
    func testMX15_unknownRawFieldFailsClosed() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        let ts = mxTS()
        let base = mxEvent("mx-raw", at: ts)
        // 以正式 encoder 產生可解碼行,再注入未知 key(測試側 oracle:直接檢查 raw JSON)。
        let encoded = try AtomicJSON.encoder().encode(base)
        var obj = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        obj["mx_future_field"] = "keep-me"
        var line = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        line.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try line.write(to: ledgerURL)
        let mock = MockAdapter("mx") { _ in mxComplete([mxEvent("mx-raw", at: ts)]) }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let raw = String(data: (try? Data(contentsOf: ledgerURL)) ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("mx_future_field"),
                      "MX15 未知 raw 欄位 ⇒ fail closed;replacement 不得靜默重編碼吞掉未知 key")
    }

    // MX16:縮小版 2026-07-26 near-miss(12 事件/3 來源全數上游刪除)→ 全數 preserve(預期紅)。
    func testMX16_reducedNearMissFixture_preserves() throws {
        let dir = makeTempDir()
        var seed: [UsageEvent] = []
        for s in 1...3 {
            for e in 1...4 {
                seed.append(mxEvent("mx-nm-s\(s)e\(e)", sourcePath: "/mx/deleted-session-\(s).jsonl"))
            }
        }
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl")).append(seed)
        let mock = MockAdapter("mx") { _ in mxComplete([]) }   // 來源全刪:rescan 完整但零結果
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let ids = Set(mxReload(dir).map(\.id))
        for ev in seed {
            XCTAssertTrue(ids.contains(ev.id), "MX16 縮小 near-miss:\(ev.id) 必須逐筆保留")
        }
    }

    // MX16b:frozen dataset 隔離副本測試入口(本輪僅入口)。未設 env ⇒ 記為 SKIP;
    // 指向 production forensics 原件 ⇒ 直接失敗(保護原件);指向隔離副本 ⇒ 唯讀驗證。
    func testMX16b_frozenIsolatedCopyEntryPoint() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["AIPET_MX_FROZEN_COPY_DIR"],
              !dirPath.isEmpty else {
            print("  ⚪ MX16b skipped — AIPET_MX_FROZEN_COPY_DIR 未設定(入口保留,預設不執行)")
            XCTAssertTrue(true, "MX16b SKIPPED")
            return
        }
        // Owner-binding fixture safety(2026-07-30 裁決):在 stat/open 任何 fixture 資料檔前——
        // (1) canonical path resolve;(2) 拒絕 production forensics 原件;(3) 驗證隔離副本 sentinel。
        // 任一不符即刻 return,不得記完 assertion 後繼續。原件即使唯讀也永不作為測試輸入。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let forbidden = (home + "/Library/Application Support/AIPetUsage/forensics-2026-07-26").lowercased()
        let canonical = URL(fileURLWithPath: dirPath).resolvingSymlinksInPath()
        let resolved = canonical.path.lowercased()
        if resolved == forbidden || resolved.hasPrefix(forbidden + "/") {
            XCTAssertTrue(false, "MX16b 只接受隔離副本,拒絕 production forensics 原件路徑")
            return
        }
        let sentinel = canonical.appendingPathComponent("AIPET-ISOLATED-TEST-COPY.sentinel")
        guard FileManager.default.fileExists(atPath: sentinel.path) else {
            XCTAssertTrue(false, "MX16b 副本目錄缺 AIPET-ISOLATED-TEST-COPY.sentinel — 拒絕視為隔離 test root")
            return
        }
        let ledgerURL = canonical.appendingPathComponent("ledger.frozen.jsonl")
        let before = try Data(contentsOf: ledgerURL)
        let events = UsageLedger(fileURL: ledgerURL).events
        XCTAssertGreaterThan(events.filter { $0.providerId == "claude-code" }.count, 0,
                             "MX16b 副本含 claude-code 事件")
        let after = try Data(contentsOf: ledgerURL)
        XCTAssertEqual(before, after, "MX16b 唯讀入口:載入不得改動副本位元組")
    }

    // MX17:codex 型 enrichment——model nil→known 且全部 token 欄位不變 → replace 成功(預期綠)。
    func testMX17_codexEnrichmentTokenFieldsUnchanged_replaces() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        let toks = TokenBreakdown(input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50)
        _ = UsageLedger(fileURL: dir.appendingPathComponent("ledger.jsonl"))
            .append([mxEvent("mx-cx", provider: "mxcodex", at: ts, model: nil, tokens: toks)])
        let mock = MockAdapter("mxcodex") { _ in
            mxComplete([mxEvent("mx-cx", provider: "mxcodex", at: ts, model: "gpt-5.5", tokens: toks)])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mxcodex"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        let got = mxReload(dir).first { $0.id == "mx-cx" }
        XCTAssertEqual(mxRawIDCount(dir, "mx-cx"), 1, "MX17 raw 層恰好一行")
        XCTAssertEqual(got?.modelId, "gpt-5.5", "MX17 enrichment 生效")
        XCTAssertEqual(got?.tokens.cacheWriteUnknown, 0, "MX17 cacheWriteUnknown 不變")
        XCTAssertEqual(got?.tokens.input, 10, "MX17 input 不變")
        XCTAssertEqual(got?.tokens.output, 20, "MX17 output 不變")
        XCTAssertEqual(got?.tokens.cacheRead, 30, "MX17 cacheRead 不變")
        XCTAssertEqual(got?.tokens.cacheWrite5m, 40, "MX17 cacheWrite5m 不變")
        XCTAssertEqual(got?.tokens.cacheWrite1h, 50, "MX17 cacheWrite1h 不變")
    }

    // MX19(owner 2026-07-30):baseline raw JSONL 含兩行相同 event ID——duplicate 偵測必須發生在
    // typed decode/keep-first 去重之前;歧義 ⇒ canonicalization failure ⇒ 全量 preserve,
    // 兩行 raw duplicate 都不得被靜默正規化成單一 event(預期紅:現行 load 去重 + compact/replace 重寫)。
    func testMX19_rawDuplicateBaselineID_failsClosed() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        let ts = mxTS()
        let encoder = AtomicJSON.encoder()
        var blob = Data()
        blob.append(try encoder.encode(mxEvent("mx-rd", at: ts, tokens: TokenBreakdown(input: 100))))
        blob.append(0x0A)
        blob.append(try encoder.encode(mxEvent("mx-rd", at: ts, tokens: TokenBreakdown(input: 200))))
        blob.append(0x0A)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try blob.write(to: ledgerURL)
        XCTAssertEqual(mxRawIDCount(dir, "mx-rd"), 2, "MX19 前置:raw 層確實存在兩行相同 ID")
        let mock = MockAdapter("mx") { _ in
            mxComplete([mxEvent("mx-rd", at: ts, tokens: TokenBreakdown(input: 100))])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        XCTAssertEqual(mxRawIDCount(dir, "mx-rd"), 2,
                       "MX19 raw duplicate ⇒ fail closed 全量 preserve;兩行 raw 證據不得被正規化/重寫消滅")
    }

    // MX20(owner 2026-07-30):空 baseline + complete 非空 candidate(無 duplicate、canonicalization 可過)
    // ⇒ 合法建立初始 slice——證明 history gate 不會把初始化誤判為回退(預期綠)。
    func testMX20_emptyBaselineCompleteCandidate_initializes() throws {
        let dir = makeTempDir()
        let ts = mxTS()
        let mock = MockAdapter("mx") { _ in
            mxComplete([mxEvent("mx-n1", at: ts), mxEvent("mx-n2", at: ts)])
        }
        let coord = UsageCoordinator(dataDir: dir, settings: mxSettings(["mx"]), adapters: [mock])
        _ = mxRun(coord, fullReindex: true)
        for want in ["mx-n1", "mx-n2"] {
            XCTAssertEqual(mxReload(dir).filter { $0.id == want }.count, 1, "MX20 \(want) 恰好一筆")
            XCTAssertEqual(mxRawIDCount(dir, want), 1, "MX20 \(want) raw 層亦恰好一行")
        }
    }

    // MX18:replacement 失敗/中斷 ⇒ 不留 partial slice(直接對 UsageLedger 施壓;預期綠)。
    func testMX18_replacementFailureNoPartialSlice() throws {
        let dir = makeTempDir()
        let ledgerURL = dir.appendingPathComponent("ledger.jsonl")
        let ledger = UsageLedger(fileURL: ledgerURL)
        _ = ledger.append([mxEvent("mx-e1"), mxEvent("mx-e2")])
        let bytesBefore = try Data(contentsOf: ledgerURL)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)   // 目錄唯讀 → 原子替換必失敗
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        // root 會無視 mode bits(sibling 測試同款防護):可寫則自我跳過,不產生假紅。
        let probe = dir.appendingPathComponent(".mx-probe")
        if (try? Data("x".utf8).write(to: probe)) != nil {
            try? fm.removeItem(at: probe)
            print("  ⚪ MX18 skipped — 目錄唯讀無效(root?),無法注入寫入失敗")
            return
        }
        var threw = false
        do { _ = try ledger.replaceProviderSlice("mx", with: [mxEvent("mx-e3")]) } catch { threw = true }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertTrue(threw, "MX18 寫入失敗必須 throw,不得靜默")
        XCTAssertEqual(try Data(contentsOf: ledgerURL), bytesBefore, "MX18 磁碟逐位元組不變(無 partial)")
        let ids = Set(ledger.events.map(\.id))
        XCTAssertTrue(ids.contains("mx-e1") && ids.contains("mx-e2") && !ids.contains("mx-e3"),
                      "MX18 記憶體維持 baseline,無半套用")
    }
}
