import Foundation
@testable import UsageCore

// MARK: - #64 P4/P5:durable-commit crash matrix(preregistered;PLAN-v1 §5)
// C7a/b/c = seam 注入(in-session barrier failure);C1–C3 = 磁碟狀態構造 + restart。
// C4(ledger durable / watermark lost → rescan+dedup)映射既有 testDeletedScanStateAdoptedAsEmpty
// 與 C-MF2 系列;C6(torn tail)映射既有 torn-tail 容忍測試 —— 不重寫(PLAN §5 注記)。
// 明示 collapse(fallback-review r1 SHOULD:preregistration 不留 silent gap):
// C7b×{F1,F4,F5} 與 C7c×{F1,F4} 折疊進 C7b×F3 / C7c×{F3,F5} —— 五個 family 全部漏斗過
// 同一 atomicWriteCapturingFingerprint,rename/dir-fsync 的 guard 在 helper 內、family 代碼
// 無從分辨哪個 guard 拋出;per-family 失敗傳播已由 C7a×4+P2 逐 family 證明。
// Owner success rule:mutation 只有在 required barrier 成功後才可 ack;bytes 可能已動之後的
// 任何失敗 = outcome-unknown + fail-closed,絕不假設 rollback。

/// 記錄式 ops:斷言呼叫順序 + 可注入單槽失敗;未注入時透傳 production 行為。
final class DurabilityOpsRecorder {
    var calls: [String] = []
    var failSyncFile = false
    /// 第 k 次 syncFile 呼叫起才失敗(nil = 不用;供「ingest 成功、sweep 失敗」類複合情境;#49)。
    var failSyncFileFrom: Int? = nil
    var failStatFile = false
    var failRename = false
    var failSyncDirectory = false

    var ops: DurabilityOps {
        DurabilityOps(
            syncFile: { fd in
                self.calls.append("syncFile")
                let nth = self.calls.filter { $0 == "syncFile" }.count
                if let from = self.failSyncFileFrom, nth >= from { return -1 }
                return self.failSyncFile ? -1 : DurabilityOps.production.syncFile(fd)
            },
            statFile: { fd, st in
                self.calls.append("statFile")
                return self.failStatFile ? -1 : DurabilityOps.production.statFile(fd, st)
            },
            renameFile: { src, dst in
                self.calls.append("rename")
                return self.failRename ? -1 : DurabilityOps.production.renameFile(src, dst)
            },
            syncDirectory: { path in
                self.calls.append("syncDirectory")
                return self.failSyncDirectory ? -1 : DurabilityOps.production.syncDirectory(path)
            })
    }
}

final class DurabilityMatrixTests: XCTestCase {
    private func ev(_ id: String, _ ts: String) -> UsageEvent {
        UsageEvent(id: id, providerId: "codex", projectId: "/p/x", projectName: "x", modelId: "m",
                   timestamp: date(ts), tokens: TokenBreakdown(input: 10), sourceKind: "test")
    }

    private func seedLedger(_ dir: URL, events: [UsageEvent]) -> URL {
        let file = dir.appendingPathComponent("ledger.jsonl")
        let l = UsageLedger(fileURL: file)
        _ = l.append(events)
        precondition(l.writeError == nil)
        return file
    }

    // MARK: C7a — syncFile failure(pre-rename;唯一可斷言 destination-old-intact 的腿)

    /// F3 compact:syncFile 失敗 → .failed、原 bytes 不變、memory/revision 不推進、無殘留 temp 被消費。
    func testC7aCompactSyncFileFailureFailsClosedOldIntact() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let before = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let r0 = l.revision, e0 = l.events.map(\.id)
        let result = l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z"))
        XCTAssertEqual(result, .failed, "C7a:barrier 失敗 = mutation failed(DP-1 hard fail,不降級)")
        XCTAssertEqual(try Data(contentsOf: file), before, "C7a pre-rename:destination 必須原封不動")
        XCTAssertEqual(l.events.map(\.id), e0, "無 ack:記憶體不推進")
        XCTAssertEqual(l.revision, r0, "無 ack:revision 不推進")
        XCTAssertTrue(rec.calls.contains("syncFile"), "barrier 必須真的被呼叫")
        XCTAssertFalse(rec.calls.contains("rename"), "syncFile 失敗後不得 rename")
    }

    /// F1 first-create:missing 檔 + append,syncFile 失敗 → append 0 + writeError、dest 仍缺、temp 已清。
    func testC7aFirstCreateSyncFileFailureLeavesNoLedger() {
        let dir = makeTempDir()
        let file = dir.appendingPathComponent("ledger.jsonl")
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        XCTAssertEqual(l.append([ev("a", "2026-01-01T00:00:00Z")]), 0)
        XCTAssertNotNil(l.writeError, "C7a:無 false success ack")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "C7a:destination 仍 missing(old=empty)")
        let residue = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(residue.isEmpty, "C7a:temp best-effort unlink 已執行(殘留=\(residue))")
    }

    /// F4 compactRawPreserving:syncFile 失敗 → .failed、原 bytes 逐位保留。
    func testC7aRawPreservingSyncFileFailurePreservesOriginalBytes() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let before = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let result = l.compactRawPreserving(retentionDays: 30, now: date("2026-06-01T00:00:00Z"), raw: before)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(try Data(contentsOf: file), before, "C7a:raw 逐位保留")
        XCTAssertNil(l.loadError)
    }

    /// F5 CAS replace(preservingRaw):syncFile 失敗 → throw、memory 不變(上層 coordinator 走 preserve)。
    func testC7aCASReplaceSyncFileFailureThrowsMemoryUnchanged() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("k1", "2026-01-01T00:00:00Z")])
        let before = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let e0 = l.events.map(\.id)
        var threw = false
        do { _ = try l.replaceProviderSlice("codex", with: [ev("k2", "2026-02-01T00:00:00Z")],
                                            expectedRevision: l.loadedRevision(),
                                            preservingRaw: before) } catch { threw = true }
        XCTAssertTrue(threw, "C7a:barrier 失敗必須 throw")
        XCTAssertEqual(l.events.map(\.id), e0, "no ack:memory 不變")
        XCTAssertEqual(try Data(contentsOf: file), before, "C7a pre-rename:destination 原封")
    }

    // MARK: P1 pre-rename fstat failure(attempt-002 owner-accepted MUST-FIX:verify 步失敗
    // = pre-rename failure,與 C7a 同腿——destination 未動、可零歧義 abort,絕無理由帶著
    // 未知指紋執行 destructive rename)

    /// F3 代表:statFile(fstat temp fd)失敗 → .failed、dest 原封、temp 清、無 ack、不 rename。
    func testP1PreRenameStatFailureFailsClosedOldIntact() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let before = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failStatFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let r0 = l.revision, e0 = l.events.map(\.id)
        XCTAssertEqual(l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .failed,
                       "P1:fstat 失敗 = pre-rename failure,不得 ack")
        XCTAssertEqual(try Data(contentsOf: file), before, "destination 必須原封(rename 不得發生)")
        XCTAssertEqual(l.events.map(\.id), e0, "無 ack:記憶體不推進")
        XCTAssertEqual(l.revision, r0)
        XCTAssertFalse(rec.calls.contains("rename"), "fstat 失敗後不得 rename")
        let residue = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(residue, ["ledger.jsonl"], "temp best-effort unlink(殘留=\(residue))")
    }

    // MARK: C7b — rename failure(destination 仍 old)

    func testC7bCompactRenameFailureFailsClosedOldIntact() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let before = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failRename = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        XCTAssertEqual(l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .failed)
        XCTAssertEqual(try Data(contentsOf: file), before, "C7b:rename 失敗 → destination old")
        XCTAssertEqual(rec.calls.filter { $0 == "syncFile" }.count, 1, "順序:syncFile 已跑")
        XCTAssertFalse(rec.calls.contains("syncDirectory"), "rename 失敗後不得 syncDirectory")
    }

    // MARK: C7c — syncDirectory failure(post-rename;outcome UNKNOWN,絕不斷言/回滾 old)

    /// F3:c 腿 —— 不 ack、不推進 memory/revision、needsReload;restart 得 {old|new} 之一且 valid。
    /// (此注入下真 rename 已執行,實際磁碟=new —— 斷言刻意寫成「兩者皆合法」而非鎖定 new。)
    func testC7cCompactDirSyncFailureOutcomeUnknownFailClosed() throws {
        let dir = makeTempDir()
        let oldEvents = [ev("old1", "2020-01-01T00:00:00Z"), ev("new1", "2026-05-15T00:00:00Z")]
        let file = seedLedger(dir, events: oldEvents)
        let rec = DurabilityOpsRecorder(); rec.failSyncDirectory = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let r0 = l.revision, e0 = l.events.map(\.id)
        XCTAssertEqual(l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .failed,
                       "C7c:barrier 未全部成功 = 不得 ack(即使 rename 已可見)")
        XCTAssertEqual(l.events.map(\.id), e0, "no ack:memory 不推進(不採用 unknown 結果)")
        XCTAssertEqual(l.revision, r0)
        XCTAssertTrue(l.hasUnreconciledSnapshot, "C7c:needsReload —— 下輪對帳實際磁碟")
        // restart:允許 {old | new},兩者都必須是 valid 解析(絕無 silently-empty/poisoned)。
        let restarted = UsageLedger(fileURL: file)
        XCTAssertNil(restarted.loadError)
        let ids = restarted.events.map(\.id)
        let oldIDs = oldEvents.map(\.id).sorted()
        let newIDs = ["new1"]
        XCTAssertTrue(ids.sorted() == oldIDs || ids.sorted() == newIDs,
                      "C7c restart:必須是 old 或 new 之一(得到 \(ids))")
    }

    /// F5 CAS:c 腿同契約 —— throw、memory 不動、needsReload。
    func testC7cCASReplaceDirSyncFailureOutcomeUnknownFailClosed() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("k1", "2026-01-01T00:00:00Z")])
        let raw = try Data(contentsOf: file)
        let rec = DurabilityOpsRecorder(); rec.failSyncDirectory = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        let e0 = l.events.map(\.id)
        var threw = false
        do { _ = try l.replaceProviderSlice("codex", with: [ev("k2", "2026-02-01T00:00:00Z")],
                                            expectedRevision: l.loadedRevision(),
                                            preservingRaw: raw) } catch { threw = true }
        XCTAssertTrue(threw, "C7c:dir barrier 失敗必須 throw(不得 ack)")
        XCTAssertEqual(l.events.map(\.id), e0, "no ack")
        XCTAssertTrue(l.hasUnreconciledSnapshot, "outcome unknown → 強制下輪對帳")
    }

    // MARK: P2 — append-in-place barrier(F2)

    /// F2 C7:tail sync 失敗 → 無 ack、無 memory commit、needsReload;「disk unchanged」絕不宣稱。
    /// reload 後必須是 {吸收完整 append | torn-tail 容忍後的 old} 之一,絕非 poisoned。
    func testC7P2AppendSyncFailureNoAckOutcomeUnknown() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("base", "2026-01-01T00:00:00Z")])
        let rec = DurabilityOpsRecorder(); rec.failSyncFile = true
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        XCTAssertEqual(l.append([ev("tail", "2026-03-01T00:00:00Z")]), 0, "no false success")
        XCTAssertNotNil(l.writeError)
        XCTAssertFalse(l.events.contains { $0.id == "tail" }, "no memory commit")
        l.clearWriteError()
        l.reloadIfChanged()
        XCTAssertNil(l.loadError, "reload:合法狀態(full append 或 torn-tail),絕非 poisoned")
        let ids = Set(l.events.map(\.id))
        XCTAssertTrue(ids == ["base"] || ids == ["base", "tail"],
                      "outcome unknown:{old | full-append} 之一(得到 \(ids))")
    }

    // MARK: 順序斷言(P1 恰一組有序三呼叫;P2 恰一次 syncFile)

    func testP1BarrierCallOrder() {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let rec = DurabilityOpsRecorder()
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        XCTAssertEqual(l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .applied)
        XCTAssertEqual(rec.calls, ["syncFile", "statFile", "rename", "syncDirectory"],
                       "P1 barrier 順序恆為 syncFile → statFile → rename → syncDirectory(得到 \(rec.calls))")
    }

    func testP2ExactlyOneSyncFilePerAppendNoRename() {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("base", "2026-01-01T00:00:00Z")])
        let rec = DurabilityOpsRecorder()
        let l = UsageLedger(fileURL: file, durabilityOps: rec.ops)
        XCTAssertEqual(l.append([ev("tail", "2026-03-01T00:00:00Z")]), 1)
        XCTAssertEqual(rec.calls, ["syncFile"], "in-place append:恰一次 syncFile、無 rename/syncDirectory(得到 \(rec.calls))")
    }

    // MARK: 6b-3 — pre-rename fingerprint 等價(用測試鎖,不靠推理)

    /// P1 於 temp fd 捕捉的指紋必須等價於 rename 後 destination 的實際指紋。
    /// 證法:compact applied 後緊接 append —— MF2 preflight 要求 currentFingerprint(dest) ==
    /// expectedFingerprint(P1 捕捉值);append 成功(=1)即等價成立,失敗(=0)即不等價。
    func testFingerprintEquivalenceAcrossRename() {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let l = UsageLedger(fileURL: file)
        XCTAssertEqual(l.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .applied)
        XCTAssertEqual(l.append([ev("post", "2026-06-02T00:00:00Z")]), 1,
                       "append 過 MF2 指紋 preflight ⟺ P1 pre-rename 捕捉 == rename 後磁碟指紋")
        XCTAssertNil(l.writeError)
    }

    // MARK: C1/C2/C3 — 磁碟狀態構造 + restart(regression lock)

    /// C1/C2:temp 殘留 + old 完好 → restart 讀 old;殘留 inert、不被 parser 消費、不擋下次 mutation。
    func testC1TempResidueInertOldIntactNextMutationProceeds() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("a", "2026-01-01T00:00:00Z")])
        let residue = dir.appendingPathComponent(".ledger.jsonl.tmp-DEADBEEF")
        try Data("garbage not json\n".utf8).write(to: residue)
        let l = UsageLedger(fileURL: file)
        XCTAssertNil(l.loadError, "殘留 temp 不影響 load")
        XCTAssertEqual(l.events.map(\.id), ["a"], "restart = old")
        XCTAssertEqual(l.append([ev("b", "2026-02-01T00:00:00Z")]), 1, "orphan 不擋下一次 mutation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: residue.path), "#64 不掃 orphan(DP-2)")
    }

    /// C3(new 已可見):restart 讀 new(P1 保證 new 絕不短檔 —— 由順序斷言鎖)。
    func testC3RenameVisibleNewValidRestart() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("old1", "2020-01-01T00:00:00Z"),
                                            ev("new1", "2026-05-15T00:00:00Z")])
        let l0 = UsageLedger(fileURL: file)
        XCTAssertEqual(l0.compact(retentionDays: 30, now: date("2026-06-01T00:00:00Z")), .applied)
        let restarted = UsageLedger(fileURL: file)
        XCTAssertNil(restarted.loadError)
        XCTAssertEqual(restarted.events.map(\.id), ["new1"], "C3-new:restart 讀 new")
    }

    /// C3 power-loss 短檔(torn tail on rewrite target)→ old-prefix 容忍,絕非 silently-empty-valid。
    /// (P1 落地後此狀態不再由 P1 產生;此測試鎖 restart 分類本身。)
    func testC3TornWriteRestartToleratedNeverSilentlyEmpty() throws {
        let dir = makeTempDir()
        let file = seedLedger(dir, events: [ev("a", "2026-01-01T00:00:00Z"),
                                            ev("b", "2026-02-01T00:00:00Z")])
        var data = try Data(contentsOf: file)
        data.removeLast(7)   // 切斷最後一行 → torn tail
        try data.write(to: file)
        let l = UsageLedger(fileURL: file)
        XCTAssertNil(l.loadError, "torn tail = 容忍(續寫復原路徑)")
        XCTAssertEqual(l.events.map(\.id), ["a"], "old-prefix 保留;絕不把非空檔讀成空而照常營業")
    }
}
