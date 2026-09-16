import Foundation
@testable import UsageCore   // crash-during case 需 DurabilityOps 注入(internal;debug enable-testing)

// P0-B design v3.3(canonical sha256 72b14b31…)red-first。
// §2 classifier unification:ledgerEventClassifier = ISO8601.parse(strict:) 為唯一 classifier;
// ledger event-line typed decode 必須與 removal 判準同源(r4 verified blocker 的修正)。
// gap 類 = r4 probe 實證的 typed(.iso8601)接受 ∧ strict 拒絕字串(countable-not-removable)。
final class ClassifierUnificationTests: XCTestCase {

    /// r4 probe 八類(過期樣式,2000 年;Foundation .iso8601 收、strict 拒)。
    static let gapTimestamps: [String] = [
        "2000-01-01T00:00:00+15:00",   // offset 超上界(strict ≤ +14:00)
        "2000-01-01T00:00:00-13:00",   // offset 超下界(strict ≥ −12:00)
        "2000-01-01T00:00:00+08:60",   // tzMin > 59
        "2000-01-01T23:59:60Z",        // leap second(反解不相等)
        "2000-01-01T24:00:00Z",        // 24 時 roll-over
        "2000-02-30T00:00:00Z",        // invalid day normalize
        "2000-01-01T00:00:00Zgarbage", // 垃圾後綴(整串消耗拒)
        "0000-01-01T00:00:00Z",        // 年 0000(反解不相等)
    ]

    private func makeLine(id: String, provider: String = "claude-code", ts: String) throws -> String {
        let e = UsageEvent(id: id, providerId: provider, timestamp: Date(timeIntervalSince1970: 0),
                           tokens: TokenBreakdown(input: 1), sourceKind: "test")
        let data = try AtomicJSON.encoder().encode(e)
        var s = String(decoding: data, as: UTF8.self)
        // encoder .iso8601 對 epoch 0 輸出固定 "1970-01-01T00:00:00Z" —— 替換為目標 timestamp。
        guard s.contains("1970-01-01T00:00:00Z") else { throw JSONCodecError.notADictionary }
        s = s.replacingOccurrences(of: "1970-01-01T00:00:00Z", with: ts)
        return s
    }

    private func writeLedger(lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// v3.3 §2:strict-rejected 行不得成為 typed event(= raw-only);membership 經
    /// containsEvent 保留(id 在 reservedRawIDs)。
    func testGapTimestampLinesAreRawOnlyNotTyped() throws {
        var lines: [String] = [try makeLine(id: "ok-1", ts: ISO8601.format(Date()))]
        for (i, ts) in Self.gapTimestamps.enumerated() {
            lines.append(try makeLine(id: "gap-\(i)", ts: ts))
        }
        let ledger = UsageLedger(fileURL: try writeLedger(lines: lines))
        XCTAssertNil(ledger.loadError, "mixed file must load (typed row present)")
        XCTAssertEqual(ledger.events.count, 1,
                       "strict-rejected lines must NOT enter typed events (got \(ledger.events.map(\.id)))")
        XCTAssertEqual(ledger.events.first?.id, "ok-1")
        for i in 0..<Self.gapTimestamps.count {
            XCTAssertFalse(ledger.events.contains { $0.id == "gap-\(i)" },
                           "gap-\(i) must not be typed")
            XCTAssertTrue(ledger.containsEvent(id: "gap-\(i)"),
                          "gap-\(i) must stay full-physical member (raw-only reserved)")
        }
    }

    /// v3.3 §7 identity 案:gap 過期樣式行不得 arm compactWouldAct(r4 .noop permanent
    /// loop 的釘死:scheduler 數不到 compactor 刪不掉的行)。
    func testMixedGapExpiredRowsDoNotArmCompaction() throws {
        var lines: [String] = [try makeLine(id: "ok-now", ts: ISO8601.format(Date()))]
        for (i, ts) in Self.gapTimestamps.enumerated() {
            lines.append(try makeLine(id: "gap-\(i)", ts: ts))
        }
        let ledger = UsageLedger(fileURL: try writeLedger(lines: lines))
        XCTAssertNil(ledger.loadError)
        XCTAssertFalse(ledger.compactWouldAct(retentionDays: 92, now: Date()),
                       "expired-looking strict-rejected rows must not arm compaction (countable ⇒ removable)")
    }

    /// v3.3 fail-closed:僅 strict-rejected 行的非空檔 = 解不出任何有效事件 → poisoned
    ///(與 compactRawPreserving「不提交 load()-poison 狀態」同語義、同 classifier)。
    func testAllGapFileFailsClosedAsPoisoned() throws {
        let lines = try Self.gapTimestamps.enumerated().map { try makeLine(id: "gap-\($0.0)", ts: $0.1) }
        let ledger = UsageLedger(fileURL: try writeLedger(lines: lines))
        XCTAssertTrue(ledger.loadError != nil,
                      "a non-empty file with zero classifier-accepted events must be poisoned (fail closed)")
        XCTAssertEqual(ledger.compact(retentionDays: 92, now: Date()), .poisoned)
        XCTAssertTrue(ledger.events.isEmpty)
    }

    /// converse 分類 discriminator:fractional = classifier 接受 → typed(Foundation 亦收,
    /// 兩態同);小寫 t/z = classifier 接受 → typed(Foundation 拒 → unification 前為 raw-only,
    /// 本斷言紅;unification 後綠)。torn/非 JSON 斷尾不在本測試(既有 torn-tail 容忍)。
    func testConverseAndFractionalClassificationPinned() throws {
        let lines: [String] = [
            try makeLine(id: "frac", ts: "2000-01-01T00:00:00.123Z"),
            try makeLine(id: "lower", ts: "2000-01-01t00:00:00z"),
        ]
        let ledger = UsageLedger(fileURL: try writeLedger(lines: lines))
        XCTAssertNil(ledger.loadError)
        XCTAssertTrue(ledger.events.contains { $0.id == "frac" },
                      "fractional timestamp is classifier-accepted → typed event")
        XCTAssertTrue(ledger.events.contains { $0.id == "lower" },
                      "lowercase t/z is classifier-accepted → typed event")
    }

    /// v3.3 §1b O4 raw-only arm:classifier-rejected 行的 provider 保留 full-physical
    /// 在場證據(typed 集縮小不得使 O4 證據提前消失 = non-regression)。
    func testRawOnlyProviderEvidencePreserved() throws {
        let lines = [
            try makeLine(id: "ok-1", ts: ISO8601.format(Date())),
            try makeLine(id: "gap-0", provider: "ghost", ts: "2000-01-01T00:00:00+15:00"),
        ]
        let ledger = UsageLedger(fileURL: try writeLedger(lines: lines))
        XCTAssertNil(ledger.loadError)
        XCTAssertTrue(ledger.hasRawOnlyEvidence(providerId: "ghost"),
                      "raw-only line's provider must retain full-physical evidence (O4 arm)")
        XCTAssertFalse(ledger.hasRawOnlyEvidence(providerId: "claude-code"),
                       "typed-only provider has no raw-only evidence")
        XCTAssertFalse(ledger.events.contains { $0.providerId == "ghost" },
                       "ghost's only line is raw-only, never typed")
        ledger.reloadIfChanged()
        XCTAssertTrue(ledger.hasRawOnlyEvidence(providerId: "ghost"),
                      "evidence survives reload path")
    }

    /// 健康自寫帳本零行為變化(encoder .iso8601 輸出恆 classifier-accepted)。
    func testSelfWrittenRoundTripAllTyped() throws {
        let url = try writeLedger(lines: [])
        try? FileManager.default.removeItem(at: url)   // 從不存在檔開始(空帳本合法)
        let ledger = UsageLedger(fileURL: url)
        let events = (0..<5).map { i in
            UsageEvent(id: "self-\(i)", providerId: "claude-code",
                       timestamp: Date().addingTimeInterval(Double(-i) * 3600),
                       tokens: TokenBreakdown(input: 1), sourceKind: "test")
        }
        _ = ledger.append(events)
        let reloaded = UsageLedger(fileURL: url)
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.events.count, 5, "self-written lines are always classifier-accepted")
    }
}

// v3.3 §7 red-first:邊界三點四方一致 + 可見性 non-regression(design §1/§1a/§1b)。
final class RetentionVisibilityTests: XCTestCase {

    private func makeLedger() -> (UsageLedger, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-vis-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.jsonl")
        return (UsageLedger(fileURL: url), url)
    }

    private func ev(_ id: String, _ ts: Date, provider: String = "claude-code") -> UsageEvent {
        UsageEvent(id: id, providerId: provider, timestamp: ts,
                   tokens: TokenBreakdown(input: 1), sourceKind: "test")
    }

    /// §7 邊界(#1 predicate):cutoff−1s expired / cutoff KEPT / cutoff+1s retained,
    /// 四方一致:predicate ≡ compact drop ≡ product(newestRetainedEvent)≡ retained interval。
    func testBoundaryThreePointsFourWayAgreement() {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let (ledger, _) = makeLedger()
        _ = ledger.append([
            ev("below", cutoff.addingTimeInterval(-1), provider: "p-below"),
            ev("at",    cutoff,                        provider: "p-at"),
            ev("above", cutoff.addingTimeInterval(1),  provider: "p-above"),
        ])
        // 1) predicate
        XCTAssertTrue(UsageLedger.isExpired(cutoff.addingTimeInterval(-1), retentionDays: days, now: now))
        XCTAssertFalse(UsageLedger.isExpired(cutoff, retentionDays: days, now: now), "== cutoff 屬 KEPT")
        XCTAssertFalse(UsageLedger.isExpired(cutoff.addingTimeInterval(1), retentionDays: days, now: now))
        // 2) product newestRetainedEvent(per-provider)
        XCTAssertNil(ledger.newestRetainedEvent(providerId: "p-below", retentionDays: days, now: now))
        XCTAssertEqual(ledger.newestRetainedEvent(providerId: "p-at", retentionDays: days, now: now)?.id, "at")
        XCTAssertEqual(ledger.newestRetainedEvent(providerId: "p-above", retentionDays: days, now: now)?.id, "above")
        // 3) retained interval 事件集(clamp 起點 = cutoff;含 == cutoff)
        let retained = UsageLedger.retainedInterval(retentionDays: days, now: now)
        var seen: [String] = []
        ledger.forEachEvent(in: retained) { seen.append($0.id) }
        XCTAssertEqual(Set(seen), ["at", "above"], "interval [cutoff, now) 含 == cutoff、排除 < cutoff")
        // 4) compact drop(同一 predicate;物理刪除唯 below)
        XCTAssertEqual(ledger.compact(retentionDays: days, now: now), .applied)
        XCTAssertEqual(Set(ledger.events.map(\.id)), ["at", "above"])
    }

    /// §7 可見性(#2 non-regression):過期事件物理在場 → product 不可見;
    /// **但** O4/full-physical 仍見(hasPriorEvidence 的 newestEvent 源)。
    func testExpiredPhysicalInvisibleToProductButVisibleToO4() {
        let now = Date()
        let days = 92
        let old = now.addingTimeInterval(-Double(days + 49) * 86400)   // 141d 前(過期)
        let (ledger, _) = makeLedger()
        _ = ledger.append([
            ev("a-old", old, provider: "A"),
            ev("a-old2", old.addingTimeInterval(86400), provider: "A"),  // 連續兩過期日(判別 streak 窗)
            ev("a-new", now.addingTimeInterval(-60), provider: "A"),
            ev("b-old", old.addingTimeInterval(1), provider: "B"),      // B 僅過期事件
        ])
        // product 面
        XCTAssertEqual(ledger.newestRetainedEvent(providerId: "A", retentionDays: days, now: now)?.id, "a-new")
        XCTAssertNil(ledger.newestRetainedEvent(providerId: "B", retentionDays: days, now: now),
                     "B 僅過期(未壓縮)事件 → product 空狀態")
        // streak retained 版不含過期日;full-history 版(既有語義)含
        let retained = UsageLedger.retainedInterval(retentionDays: days, now: now)
        let utc = Calendar.current
        let sRetained = ledger.usageStreak(in: retained, now: now, calendar: utc)
        let sFull = ledger.usageStreak(now: now, calendar: utc)
        XCTAssertEqual(sRetained.longest, 1, "retained 窗內僅今天一日(過期連續兩日不得計入)")
        XCTAssertEqual(sFull.longest, 2, "full-history 版(既有語義)仍見過期連續兩日")
        // O4/full-physical 面(§1b:typed 過期事件仍是 full-physical evidence)
        XCTAssertNotNil(ledger.newestEvent(providerId: "B"), "O4 全量 newestEvent 必須仍見過期事件")
        XCTAssertTrue(ledger.containsEvent(id: "b-old"))
        // 物理在場不變(未 compact)
        XCTAssertEqual(ledger.events.count, 4)
    }

    /// clampToRetained:起點 clamp、end 不動、全過期 → 空區間。
    func testClampToRetainedGeometry() {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let allTime = DateInterval(start: .distantPast, end: now)
        let clamped = UsageLedger.clampToRetained(allTime, retentionDays: days, now: now)
        XCTAssertEqual(clamped.start, cutoff)
        // DateInterval 以 start+duration 表示,distantPast 量級下 end 重算有 μs 級浮點捨入;
        // 事件時戳為秒級粒度,production 無實質影響 —— 容差斷言。
        XCTAssertTrue(abs(clamped.end.timeIntervalSince(now)) < 0.001)
        let inside = DateInterval(start: cutoff.addingTimeInterval(3600), end: now)
        XCTAssertEqual(UsageLedger.clampToRetained(inside, retentionDays: days, now: now), inside,
                       "窗內區間不動")
        let fullyExpired = DateInterval(start: .distantPast, end: cutoff.addingTimeInterval(-3600))
        let empty = UsageLedger.clampToRetained(fullyExpired, retentionDays: days, now: now)
        XCTAssertEqual(empty.start, empty.end, "全過期請求收斂為空區間(start == end == cutoff)")
        XCTAssertEqual(empty.start, cutoff)
    }
}

// v3.3 §3 gate projection(design RAM_P0B_RETENTION;merge bar 3):
// 合法 logical expiry 不觸發 history-loss;不可證明過期不豁免;等價性主張。
final class GateProjectionTests: XCTestCase {

    private func line(_ id: String, ts: String, provider: String = "p") throws -> Data {
        let e = UsageEvent(id: id, providerId: provider, timestamp: Date(timeIntervalSince1970: 0),
                           tokens: TokenBreakdown(input: 1), sourceKind: "test")
        var s = String(decoding: try AtomicJSON.encoder().encode(e), as: UTF8.self)
        s = s.replacingOccurrences(of: "1970-01-01T00:00:00Z", with: ts)
        return Data((s + "\n").utf8)
    }

    private func typedEvent(_ id: String, _ ts: Date, provider: String = "p") -> UsageEvent {
        UsageEvent(id: id, providerId: provider, timestamp: ts,
                   tokens: TokenBreakdown(input: 1), sourceKind: "test")
    }

    /// §7 gate 案:reindex 帶物理過期 baseline 行 → 合法 logical expiry **不**觸發
    /// monotonic-preserve 拒絕(過期行雙側豁免;candidate 端 reindex 本就以同 now 過濾)。
    func testLegitimateExpiryDoesNotTripGate() throws {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let keptTs = ISO8601.format(now.addingTimeInterval(-3600))
        var raw = Data()
        raw.append(try line("expired-1", ts: ISO8601.format(cutoff.addingTimeInterval(-86400))))
        raw.append(try line("kept-1", ts: keptTs))
        // candidate = reindex 以同 now cutoff 過濾後的形狀(僅 retained)
        let candidate = [typedEvent("kept-1", ISO8601.parse(keptTs, strict: true)!)]
        let decision = UsageCoordinator.monotonicGateDecision(
            baselineRaw: raw, providerId: "p", candidate: candidate,
            retentionDays: days, now: now)
        XCTAssertEqual(decision, .pass,
                       "可證明過期的 baseline 行缺席 = 合法 expiry,不得判 history loss")
    }

    /// 不可證明過期(lenient-only / 值域外 timestamp)→ 不豁免:缺席仍 preserve(fail-closed;
    /// 豁免集 ≡ compact 將刪集 —— compact 不會刪它,gate 也不得假設它可消失)。
    func testUnprovableExpiryMissingStillPreserves() throws {
        let now = Date()
        let days = 92
        var raw = Data()
        raw.append(try line("gap-old", ts: "2000-01-01T00:00:00+15:00"))   // classifier-rejected(過期樣式)
        raw.append(try line("kept-1", ts: ISO8601.format(now.addingTimeInterval(-3600))))
        let candidate = [typedEvent("kept-1", now.addingTimeInterval(-3600))]
        let decision = UsageCoordinator.monotonicGateDecision(
            baselineRaw: raw, providerId: "p", candidate: candidate,
            retentionDays: days, now: now)
        guard case .preserve(_, let missing, _, _, _) = decision, missing >= 1 else {
            XCTAssertTrue(false, "不可證明過期的行缺席必須 preserve,實得 \(decision)"); return
        }
        XCTAssertTrue(true)
    }

    /// retained 行缺席 → preserve(projection 不得誤傷未過期行)。
    func testNonExpiredMissingStillPreserves() throws {
        let now = Date()
        var raw = Data()
        raw.append(try line("kept-1", ts: ISO8601.format(now.addingTimeInterval(-7200))))
        raw.append(try line("kept-2", ts: ISO8601.format(now.addingTimeInterval(-3600))))
        let candidate = [typedEvent("kept-2", now.addingTimeInterval(-3600))]
        let decision = UsageCoordinator.monotonicGateDecision(
            baselineRaw: raw, providerId: "p", candidate: candidate,
            retentionDays: 92, now: now)
        guard case .preserve(_, let missing, _, _, _) = decision, missing == 1 else {
            XCTAssertTrue(false, "retained 行缺席必須 preserve,實得 \(decision)"); return
        }
        XCTAssertTrue(true)
    }

    /// §3 等價性(red-first 待證主張):projected-gate verdict ==
    /// 「先以同一 now 物理 compact baseline,再無-projection 比較」的 verdict。
    func testEquivalenceProjectedVsPhysicallyCompactedBaseline() throws {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let keptTs = ISO8601.format(now.addingTimeInterval(-3600))
        var raw = Data()
        raw.append(try line("expired-1", ts: ISO8601.format(cutoff.addingTimeInterval(-86400))))
        raw.append(try line("expired-2", ts: ISO8601.format(cutoff.addingTimeInterval(-1))))
        raw.append(try line("kept-1", ts: keptTs))
        let candidate = [typedEvent("kept-1", ISO8601.parse(keptTs, strict: true)!)]
        // 路徑 A:projected gate
        let projected = UsageCoordinator.monotonicGateDecision(
            baselineRaw: raw, providerId: "p", candidate: candidate,
            retentionDays: days, now: now)
        // 路徑 B:同一 now 物理 compact baseline(compactRawPreserving 於實檔)→ 大 retention
        //(projection 空集)比較 —— 即「無 projection 的 gate 對已壓縮 baseline」。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-equiv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.jsonl")
        try raw.write(to: url)
        let ledger = UsageLedger(fileURL: url)
        XCTAssertEqual(ledger.compactRawPreserving(retentionDays: days, now: now, raw: raw), .applied)
        let compactedRaw = try Data(contentsOf: url)
        let physical = UsageCoordinator.monotonicGateDecision(
            baselineRaw: compactedRaw, providerId: "p", candidate: candidate,
            retentionDays: 36500, now: now)
        XCTAssertEqual(projected, physical, "延後物理 compact 不改變 gate 判決(等價性)")
        XCTAssertEqual(projected, .pass)
    }

    /// projectRetained 等號邊界(P0-B impl xcheck r1 sol-F3,test-only):timestamp == cutoff 屬
    /// retained(canonical:`< cutoff` expired、`== cutoff` KEPT)—— 不豁免;candidate 缺它必
    /// preserve,且與「同 now 物理 compact(isExpired `<` 保留 == cutoff)後比較」的判決等價。
    /// `>=`→`>` mutation 會把該行豁免掉 ⇒ projected 誤 pass ⇒ 本測試紅。
    func testEventAtCutoffIsRetainedNotExempt() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))   // 整秒:ISO8601.format 不帶小數
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let atTs = ISO8601.format(cutoff)
        XCTAssertEqual(ISO8601.parse(atTs, strict: true), cutoff, "fixture 前提:== cutoff 精確往返")
        let keptTs = ISO8601.format(now.addingTimeInterval(-3600))
        var raw = Data()
        raw.append(try line("expired-1", ts: ISO8601.format(cutoff.addingTimeInterval(-1))))
        raw.append(try line("at-cutoff", ts: atTs))
        raw.append(try line("kept-1", ts: keptTs))
        // 1) projection 本身:== cutoff 保留、< cutoff 豁免
        guard case .success(let whole) = CanonicalLedgerV1.canonicalizeRawLines(raw) else {
            XCTAssertTrue(false, "fixture raw 必須可 canonicalize"); return
        }
        XCTAssertEqual(Set(CanonicalLedgerV1.projectRetained(whole, cutoff: cutoff).events.keys),
                       ["at-cutoff", "kept-1"], "== cutoff 屬 retained;僅 < cutoff 豁免")
        // 2) gate:candidate 缺 at-cutoff ⇒ 這是 retained 行遺失,必 preserve(missing 1)
        let candidate = [typedEvent("kept-1", ISO8601.parse(keptTs, strict: true)!)]
        let projected = UsageCoordinator.monotonicGateDecision(
            baselineRaw: raw, providerId: "p", candidate: candidate,
            retentionDays: days, now: now)
        guard case .preserve(_, let missingP, _, _, _) = projected, missingP == 1 else {
            XCTAssertTrue(false, "== cutoff 行缺席必須 preserve(missing 1),實得 \(projected)"); return
        }
        // 3) 等價:同 now 物理 compact(compactRawPreserving 以 isExpired `<`,== cutoff 保留)後
        //    以大 retention 比較,判決同為 preserve/missing 1(retained 計數為未投影 baseline 行數,
        //    兩路徑本就不同,不在等價主張內)。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-equiv-eq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ledger.jsonl")
        try raw.write(to: url)
        let ledger = UsageLedger(fileURL: url)
        XCTAssertEqual(ledger.compactRawPreserving(retentionDays: days, now: now, raw: raw), .applied)
        let physical = UsageCoordinator.monotonicGateDecision(
            baselineRaw: try Data(contentsOf: url), providerId: "p", candidate: candidate,
            retentionDays: 36500, now: now)
        guard case .preserve(_, let missingQ, _, _, _) = physical, missingQ == 1 else {
            XCTAssertTrue(false, "物理 compact 後 == cutoff 行仍在,缺席必 preserve(missing 1),實得 \(physical)"); return
        }
        XCTAssertTrue(true)
    }
}

// v3.3 §2/§7 scheduler 批次化(owner B2:N_batch=64 / T_max=1h;排程枚舉 + restart recompute
// + same-snapshot completeness)。
final class SchedulerBatchingTests: XCTestCase {

    private func makeURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-sched-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.jsonl")
    }

    private func ev(_ id: String, _ ts: Date) -> UsageEvent {
        UsageEvent(id: id, providerId: "p", timestamp: ts,
                   tokens: TokenBreakdown(input: 1), sourceKind: "test")
    }

    /// owner 枚舉:63 → 不壓;64 → 壓(N_batch);1+<1h → 不壓;1+≥1h → 壓(overdue);
    /// 0 → 不壓(硬鎖:timer 單獨絕不重寫)。
    func testScheduleEnumeration() {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)

        // 63 expired(overdueAge 全 < 1h)+ 1 retained → 無 count 觸發、無 timer 觸發
        let l63 = UsageLedger(fileURL: makeURL())
        _ = l63.append((0..<63).map { ev("e\($0)", cutoff.addingTimeInterval(-Double($0 + 60))) }
                      + [ev("keep", now.addingTimeInterval(-60))])
        XCTAssertFalse(l63.shouldPhysicallyCompact(retentionDays: days, now: now), "63 expired 不壓縮")
        XCTAssertTrue(l63.compactWouldAct(retentionDays: days, now: now), "舊判定仍會急壓(對照)")

        // 64 expired → N_batch 觸發
        let l64 = UsageLedger(fileURL: makeURL())
        _ = l64.append((0..<64).map { ev("e\($0)", cutoff.addingTimeInterval(-Double($0 + 60))) })
        XCTAssertTrue(l64.shouldPhysicallyCompact(retentionDays: days, now: now), "64 expired 壓縮(N_batch)")

        // 1 expired + overdueAge < 1h → 不壓
        let lFresh = UsageLedger(fileURL: makeURL())
        _ = lFresh.append([ev("e0", cutoff.addingTimeInterval(-1800)), ev("keep", now.addingTimeInterval(-60))])
        XCTAssertFalse(lFresh.shouldPhysicallyCompact(retentionDays: days, now: now), "overdue 30min 不壓縮")

        // 1 expired + overdueAge ≥ 1h → 壓(overdue)
        let lOverdue = UsageLedger(fileURL: makeURL())
        _ = lOverdue.append([ev("e0", cutoff.addingTimeInterval(-7200)), ev("keep", now.addingTimeInterval(-60))])
        XCTAssertTrue(lOverdue.shouldPhysicallyCompact(retentionDays: days, now: now), "overdue 2h 壓縮")

        // 1 expired + overdueAge == 1h(T_max 等號邊界;P0-B impl xcheck r1 grok-G3-F2,test-only):
        // 設計 ≥1h ⇒ eligible;`>=`→`>` mutation 必紅
        let lEdge = UsageLedger(fileURL: makeURL())
        _ = lEdge.append([ev("e0", cutoff.addingTimeInterval(-3600)), ev("keep", now.addingTimeInterval(-60))])
        XCTAssertTrue(lEdge.shouldPhysicallyCompact(retentionDays: days, now: now), "overdue == 1h 壓縮(T_max 等號屬 eligible)")

        // 0 expired → 硬鎖
        let lNone = UsageLedger(fileURL: makeURL())
        _ = lNone.append([ev("keep", now.addingTimeInterval(-60))])
        XCTAssertFalse(lNone.shouldPhysicallyCompact(retentionDays: days, now: now), "零過期絕不重寫")
    }

    /// crash-BEFORE-attempt(§7;r2 dilemma 關閉面):trigger 由 durable timestamps +
    /// then-current cutoff 重算 —— restart(新 instance)不 reset、不每 restart 一次。
    func testRestartRecomputesFromDurableLedger() {
        let now = Date()
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let url = makeURL()
        let a = UsageLedger(fileURL: url)
        _ = a.append([ev("e0", cutoff.addingTimeInterval(-7200)), ev("keep", now.addingTimeInterval(-60))])
        XCTAssertTrue(a.shouldPhysicallyCompact(retentionDays: days, now: now))
        // restart = 全新 instance 由 durable bytes 重算 → 同判定(不 reset)
        let b = UsageLedger(fileURL: url)
        XCTAssertTrue(b.shouldPhysicallyCompact(retentionDays: days, now: now),
                      "restart 重算自 durable ledger,eligibility 不 reset")
        // 未達門檻案的 restart 同樣不「每 restart 強制一次」
        let url2 = makeURL()
        let c = UsageLedger(fileURL: url2)
        _ = c.append([ev("e0", cutoff.addingTimeInterval(-1800)), ev("keep", now.addingTimeInterval(-60))])
        XCTAssertFalse(UsageLedger(fileURL: url2).shouldPhysicallyCompact(retentionDays: days, now: now),
                       "restart 不插入額外 heavy")
    }

    /// same-snapshot completeness(§6.4/§7):成功 compact 後,以**同一** attempt snapshot
    /// cutoff 再評 → 兩 trigger 皆 false(participating expired backlog 已清)。
    func testSuccessfulCompactClearsTriggersUnderSameSnapshot() throws {
        let now = Date()   // = attempt 的 fixed cutoff snapshot
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let url = makeURL()
        let ledger = UsageLedger(fileURL: url)
        _ = ledger.append((0..<64).map { ev("e\($0)", cutoff.addingTimeInterval(-Double($0 + 60))) }
                          + [ev("keep", now.addingTimeInterval(-60))])
        XCTAssertTrue(ledger.shouldPhysicallyCompact(retentionDays: days, now: now))
        let raw = try Data(contentsOf: url)
        XCTAssertEqual(ledger.compactRawPreserving(retentionDays: days, now: now, raw: raw), .applied)
        XCTAssertFalse(ledger.shouldPhysicallyCompact(retentionDays: days, now: now),
                       "success ⇒ 同 snapshot 下 expiredCount==0 ∧ oldestExpired==nil ⇒ 兩 trigger 皆 false")
        XCTAssertEqual(ledger.events.map(\.id), ["keep"])
    }
}

// v3.3 §7 crash-DURING-attempt contract case(fault-model contract C;測 contract 本身,
// 不測不可能的「crash 後不 retry」):K 次 interrupted attempt + restart → 不宣稱
// attempts < K(bounded-per-refresh retry residual,owner 明文接受);backlog 仍在 →
// eligible 合法保持 true;no separate scheduler state is trusted(durable bytes 不動);
// 第 K+1 次成功 → same-snapshot participating backlog 清 → 不得再觸發。
final class CrashDuringAttemptContractTests: XCTestCase {

    private func makeURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ram-p0b-crash-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.jsonl")
    }

    func testCrashDuringAttemptContractCase() throws {
        let now = Date()   // 整案固定 snapshot(same-snapshot 紀律)
        let days = 92
        let cutoff = UsageLedger.retentionCutoff(retentionDays: days, now: now)
        let url = makeURL()
        let seeder = UsageLedger(fileURL: url)
        _ = seeder.append((0..<65).map {
            UsageEvent(id: "e\($0)", providerId: "p",
                       timestamp: cutoff.addingTimeInterval(-Double($0 + 60)),
                       tokens: TokenBreakdown(input: 1), sourceKind: "test")
        } + [UsageEvent(id: "keep", providerId: "p", timestamp: now.addingTimeInterval(-60),
                        tokens: TokenBreakdown(input: 1), sourceKind: "test")])
        let raw0 = try Data(contentsOf: url)

        // interrupted attempt = durability barrier 恆敗(commit 前中斷;原檔逐位元組保留)
        let failing = DurabilityOps(
            syncFile: { _ in -1 },
            statFile: { fd, st in fstat(fd, st) },
            renameFile: { s, d in Darwin.rename(s, d) },
            syncDirectory: { _ in 0 })

        for k in 0..<3 {   // K 次 restart,各恰一次 attempt(≤1/refresh 序列化由 coordinator 結構保證)
            let l = UsageLedger(fileURL: url, durabilityOps: failing)   // restart = 新 instance 由 durable bytes 重算
            XCTAssertTrue(l.shouldPhysicallyCompact(retentionDays: days, now: now),
                          "第 \(k) 次 restart:backlog 仍物理在場 → eligible 合法保持 true(retry 允許)")
            XCTAssertEqual(l.compactRawPreserving(retentionDays: days, now: now, raw: raw0), .failed,
                           "interrupted attempt(barrier 失敗 = crash-during 的可測形)")
            XCTAssertEqual(try Data(contentsOf: url), raw0,
                           "no separate scheduler state is trusted:失敗 attempt 不動 durable bytes")
        }

        // 第 K+1 次成功 → same-snapshot participating backlog 清 → 同 backlog 不得再觸發
        let ok = UsageLedger(fileURL: url)
        XCTAssertTrue(ok.shouldPhysicallyCompact(retentionDays: days, now: now))
        XCTAssertEqual(ok.compactRawPreserving(retentionDays: days, now: now, raw: raw0), .applied)
        XCTAssertFalse(ok.shouldPhysicallyCompact(retentionDays: days, now: now),
                       "success ⇒ 同 snapshot 下兩 trigger 皆 false(same backlog 不得 re-storm)")
        XCTAssertEqual(ok.events.map(\.id), ["keep"])
    }
}
