import Foundation
@testable import UsageCore

// MARK: - #50 authority load contract(D)
//
// Contract:authority bytes 必須通過 parse → integrity → semantic 三關才可參與計算;
// 任一關失敗即整份 reject(v1 不做 partial salvage —— 一旦有語義損壞,損壞邊界未知)。
//
// 構造注意:所有「語義不可能」的案例都經 `saveDurably` 寫出,因此 integrity digest 是**正確的**。
// 若這些案例被 reject,必定是 semantic 關卡所致,而非 integrity 關卡 —— 兩關因此被分離驗證。

final class OpenCode50AuthorityTests: XCTestCase {

    private func store(_ dir: URL) -> CumulativeAnchorStore {
        CumulativeAnchorStore(fileURL: dir.appendingPathComponent("cumulative-anchors.json"),
                              durabilityOps: .production)
    }

    private func key(_ sid: String, _ tc: Int64) -> String {
        IncarnationKey(sessionId: sid, timeCreatedMs: tc).encoded
    }

    private func event(id: String, input: Int, at: Date = Date(timeIntervalSince1970: 1_760_000_000)) -> UsageEvent {
        UsageEvent(id: id, providerId: "opencode", projectId: "/p", projectName: "p",
                   modelId: "m/x", timestamp: at, tokens: TokenBreakdown(input: input),
                   sourceKind: "opencode-session", sourcePath: "/db", providerCostUSD: nil)
    }

    private func authority(_ anchors: [String: CumulativeAnchor]) -> CumulativeAuthority {
        CumulativeAuthority(providers: ["opencode": anchors])
    }

    private func rejectedReason(_ dir: URL) -> String? {
        if case .rejected(let why) = store(dir).load() { return why }
        return nil
    }

    // MARK: 正向對照 —— 合法 authority 必須載入成功
    //
    // 這條防止 validator 日後嚴到「全部拒絕」而讓其他測試假性轉綠。
    func testValidAuthorityLoads() throws {
        let dir = makeTempDir()
        let s = store(dir)
        try s.saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1,
                accountedThrough: AnchorCounters(input: 100, output: 20, cacheRead: 3, cacheWrite: 4, cost: 1.5))
        ]))
        guard case .loaded(let a) = s.load() else {
            XCTAssertTrue(false, "合法 authority 必須載入成功")
            return
        }
        XCTAssertEqual(a.providers["opencode"]?.count, 1)
        XCTAssertEqual(a.providers["opencode"]?[key("s1", 1_000)]?.accountedThrough.input, 100)
    }

    // MARK: 檔案不存在 = absent(尚無 authority),不是 rejected
    func testAbsentFileIsAbsentNotRejected() {
        let dir = makeTempDir()
        if case .absent = store(dir).load() { return }
        XCTAssertTrue(false, "檔案不存在應為 .absent —— 這是合法初始狀態")
    }

    // MARK: integrity —— 事後移除一筆 record(digest 未重算)必須被擋
    func testIntegrityMismatchOnRecordOmissionRejected() throws {
        let dir = makeTempDir()
        let s = store(dir)
        try s.saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1, accountedThrough: AnchorCounters(input: 100)),
            key("s2", 2_000): CumulativeAnchor(epoch: 1, accountedThrough: AnchorCounters(input: 200)),
        ]))
        let url = dir.appendingPathComponent("cumulative-anchors.json")
        var a = try AtomicJSON.decoder().decode(CumulativeAuthority.self, from: try Data(contentsOf: url))
        a.providers["opencode"]?.removeValue(forKey: key("s2", 2_000))   // 保留舊 integrity 字串
        try AtomicJSON.write(a, to: url)

        XCTAssertNotNil(rejectedReason(dir),
                        "record 被移除而 digest 未重算 ⇒ 必須偵測到並整份 reject")
    }

    // MARK: D1 —— 負的 accountedThrough
    func testD1NegativeCountersRejected() throws {
        let dir = makeTempDir()
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1, accountedThrough: AnchorCounters(input: -100))
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D1:負的 accountedThrough 為不可能狀態")
    }

    // MARK: D1b —— 超出來源 sane cap 的計數
    func testD1bOverSaneCapCountersRejected() throws {
        let dir = makeTempDir()
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1,
                accountedThrough: AnchorCounters(input: 2_000_000_000_000_000))   // > 1e15 sane cap
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D1b:超出來源 sane cap 的計數不可能來自合法來源")
    }

    // MARK: D2 —— 非正 epoch
    func testD2NonPositiveEpochRejected() throws {
        let dir = makeTempDir()
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 0, accountedThrough: AnchorCounters(input: 50))
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D2:epoch 必須為正")
    }

    // MARK: D3 —— pending.target 低於 pending.previous(同 epoch 成長必須逐項不減)
    func testD3PendingTargetBelowPreviousRejected() throws {
        let dir = makeTempDir()
        let prev = AnchorCounters(input: 200)
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1, accountedThrough: prev,
                pending: PendingReconciliation(event: event(id: "oc:s1:1:200", input: 50),
                                               previous: prev,
                                               target: AnchorCounters(input: 50),   // 低於 previous
                                               epoch: 1))
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D3:同 epoch 的 target 不得低於 previous")
    }

    // MARK: D3b —— pending.previous 與 anchor.accountedThrough 不一致
    func testD3bPendingPreviousMismatchRejected() throws {
        let dir = makeTempDir()
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1,
                accountedThrough: AnchorCounters(input: 200),
                pending: PendingReconciliation(event: event(id: "oc:s1:1:100", input: 50),
                                               previous: AnchorCounters(input: 100),   // ≠ 200
                                               target: AnchorCounters(input: 150),
                                               epoch: 1))
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D3b:pending.previous 必須等於 anchor 的 accountedThrough")
    }

    // MARK: D3c —— pending.epoch 與 anchor.epoch 不一致
    func testD3cPendingEpochMismatchRejected() throws {
        let dir = makeTempDir()
        let prev = AnchorCounters(input: 100)
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 2, accountedThrough: prev,
                pending: PendingReconciliation(event: event(id: "oc:s1:2:100", input: 50),
                                               previous: prev,
                                               target: AnchorCounters(input: 150),
                                               epoch: 1))   // ≠ anchor.epoch
        ]))
        XCTAssertNotNil(rejectedReason(dir), "D3c:pending.epoch 必須等於 anchor.epoch")
    }

    // MARK: D3d —— pending.event 的 token 量與 previous→target 的差額不一致
    func testD3dPendingEventInconsistentWithTransitionRejected() throws {
        let dir = makeTempDir()
        let prev = AnchorCounters(input: 100)
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1, accountedThrough: prev,
                pending: PendingReconciliation(event: event(id: "oc:s1:1:100", input: 999),   // 應為 50
                                               previous: prev,
                                               target: AnchorCounters(input: 150),
                                               epoch: 1))
        ]))
        XCTAssertNotNil(rejectedReason(dir),
                        "D3d:pending.event 的 token 必須恰好等於 previous→target 的差額")
    }

    // MARK: incarnation key 必須可解析
    func testUnparseableIncarnationKeyRejected() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("cumulative-anchors.json")
        var a = CumulativeAuthority(providers: ["opencode": [
            "not-a-valid-key": CumulativeAnchor(epoch: 1, accountedThrough: AnchorCounters(input: 10))
        ]])
        a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
        try AtomicJSON.write(a, to: url)
        XCTAssertNotNil(rejectedReason(dir), "incarnation key 必須同時攜帶 sessionId 與 timeCreated")
    }

    // MARK: grok r2 F4 —— epoch 上界:Int.max 不是可合法演進的狀態
    //
    // 它一經 census +1 就會 trap(或寫出不可載入的後繼),所以必須在 load 就 reject,
    // 而不是等到 census。本測試跑完不 crash 本身就是「絕不 trap」的證明。
    func testEpochAtIntMaxIsRejectedNotTrapped() throws {
        let dir = makeTempDir()
        try store(dir).saveDurably(authority([
            key("s1", 1_000): CumulativeAnchor(epoch: Int.max,
                accountedThrough: AnchorCounters(input: 1))
        ]))
        let why = rejectedReason(dir)
        XCTAssertNotNil(why, "F4:epoch == Int.max 必須整份 reject(fail closed)")
        XCTAssertTrue(why?.contains("epoch") ?? false, "F4:拒絕原因必須指向 epoch:\(why ?? "nil")")
    }

    // MARK: grok r2 F3 —— digest 必須涵蓋 census boundary
    //
    // boundary 是 R1 的唯一判準(authority provenance):事後被改寫/回退而 digest
    // 照樣通過,等於 provenance 可被偽造。改動 lastCompleteCensusMs 而不重算 digest
    // 的 authority 必須被 reject。
    func testCensusBoundaryTamperIsRejectedByDigest() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("cumulative-anchors.json")
        let s = store(dir)
        var a = authority([
            key("s1", 1_000): CumulativeAnchor(epoch: 1,
                accountedThrough: AnchorCounters(input: 100))
        ])
        a.lastCompleteCensusMs = ["opencode": 5_000]
        try s.saveDurably(a)
        guard case .loaded(let clean) = s.load() else {
            XCTAssertTrue(false, "前置:合法 authority(含 boundary)必須載入成功")
            return
        }
        XCTAssertEqual(clean.lastCompleteCensusMs["opencode"], 5_000, "前置:boundary 已持久化")

        // 篡改 boundary(回退到 1)但保留原 digest —— 必須被 integrity 關拒絕。
        var tampered = clean
        tampered.lastCompleteCensusMs = ["opencode": 1]
        try AtomicJSON.write(tampered, to: url)
        let why = rejectedReason(dir)
        XCTAssertNotNil(why, "F3:boundary 被改而 digest 未重算 ⇒ 必須 reject")
        XCTAssertTrue(why?.contains("integrity") ?? false, "F3:拒絕原因必須是 integrity mismatch:\(why ?? "nil")")
    }

    // MARK: grok r3 X3 —— 非正 census boundary:digest 正確也必須整份 reject
    //
    // boundary = -1 會讓所有正常 timeCreated 走 R1(b) 全額回填(silent overcount)——
    // 與來源 timestamp 同一 sanity domain,不 clamp、不 silent drop。
    func testX3NonPositiveCensusBoundaryRejected() throws {
        for bad: Int64 in [-1, 0] {
            let dir = makeTempDir()
            let url = dir.appendingPathComponent("cumulative-anchors.json")
            var a = authority([
                key("s1", 1_000): CumulativeAnchor(epoch: 1,
                    accountedThrough: AnchorCounters(input: 10))
            ])
            a.lastCompleteCensusMs = ["opencode": bad]
            a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
            try AtomicJSON.write(a, to: url)
            let why = rejectedReason(dir)
            XCTAssertNotNil(why, "X3:boundary \(bad) 必須整份 reject(fail closed)")
            XCTAssertTrue(why?.contains("census boundary") ?? false,
                          "X3:拒絕原因必須指向 census boundary:\(why ?? "nil")")
        }
    }

    // MARK: grok r3 X5 —— pending id 篡改:digest 重算後 semantic validation 仍必須拒絕
    func testX5PendingIdMutationRejectedEvenWithRecomputedDigest() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("cumulative-anchors.json")
        let prev = AnchorCounters(input: 100)
        let target = AnchorCounters(input: 160)
        let ik = IncarnationKey(sessionId: "s1", timeCreatedMs: 1_000)
        // id 是「格式看似合理但非 canonical」的字串(模擬撞上 ledger 既有無關事件的 id)。
        let ev = UsageEvent(id: "oc2:999~other:1:0,0,0,0,0>60,0,0,0,0", providerId: "opencode",
                            projectId: "/p", projectName: "p", modelId: "m/x",
                            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                            tokens: TokenBreakdown(input: 60), sourceKind: "opencode-session",
                            sourcePath: "/db", providerCostUSD: nil)
        var a = authority([ik.encoded: CumulativeAnchor(
            epoch: 1, accountedThrough: prev,
            pending: PendingReconciliation(event: ev, previous: prev, target: target, epoch: 1))])
        a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
        try AtomicJSON.write(a, to: url)
        let why = rejectedReason(dir)
        XCTAssertNotNil(why, "X5:pending id 非 canonical ⇒ 必須整份 reject,不得讓 recovery 用它查 ledger")
        XCTAssertTrue(why?.contains("canonical accounting-operation identity") ?? false,
                      "X5:拒絕原因必須指向 canonical identity:\(why ?? "nil")")
    }

    // MARK: grok r3 X5 —— cost transition 憑空推進(event 無對應 provider cost)必須拒絕
    func testX5PendingCostTransitionWithoutProviderCostRejected() throws {
        let dir = makeTempDir()
        let url = dir.appendingPathComponent("cumulative-anchors.json")
        let prev = AnchorCounters(input: 100, cost: 0)
        let target = AnchorCounters(input: 160, cost: 1.0)   // cost +1 憑空推進
        let ik = IncarnationKey(sessionId: "s1", timeCreatedMs: 1_000)
        let ev = UsageEvent(id: ik.eventId(epoch: 1, previous: prev, target: target),
                            providerId: "opencode",
                            projectId: "/p", projectName: "p", modelId: "m/x",
                            timestamp: Date(timeIntervalSince1970: 1_760_000_000),
                            tokens: TokenBreakdown(input: 60), sourceKind: "opencode-session",
                            sourcePath: "/db", providerCostUSD: nil)   // 無 provider cost
        var a = authority([ik.encoded: CumulativeAnchor(
            epoch: 1, accountedThrough: prev,
            pending: PendingReconciliation(event: ev, previous: prev, target: target, epoch: 1))])
        a.integrity = CumulativeAnchorStore.canonicalDigest(of: a)
        try AtomicJSON.write(a, to: url)
        let why = rejectedReason(dir)
        XCTAssertNotNil(why, "X5:target.cost 推進而 event 無 provider cost ⇒ 必須 reject")
        XCTAssertTrue(why?.contains("cost transition") ?? false,
                      "X5:拒絕原因必須指向 cost transition:\(why ?? "nil")")
    }
}
