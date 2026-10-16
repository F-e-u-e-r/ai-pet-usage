import Foundation
@testable import UsageCore

// Memory P2 Option C(C1)— validate-only compaction guard 等價 oracle + fail-closed 驗收。
//
// 契約(reviews/performance/memory-p2-optionc/CONTRACT-TEST-PLAN.md §3):對每個輸入 d,
//   O1: canonicalizeRawLinesValidate(d) == nil  ⟺  canonicalizeRawLines(d) 為 .success
//   O2: 兩者皆失敗時,validate 回傳的 FailureSummary 與 .failure 的 FailureSummary **完全相等**
// O2 證明 validate 不是「較弱的語法 validator」:到達相同的分類與錯誤明細。
// 本 suite 對一組**已知正確判決**的契約向量斷言 O1∧O2(fidelity,獨立於 mutation sensitivity);
// mutation sensitivity 由 §5 falsification 程序另行建立(見 FALSIFICATION.md)。
final class MemoryP2OptionCTests: XCTestCase {

    // MARK: - builders

    /// 以 production encoder 形狀建合法行(sortedKeys);可注入 extra/缺漏以造出 reject 向量。
    private func line(id: String, provider: String = "mx", ts: String = "2026-07-29T00:00:00Z",
                      tokensInput: Int = 100, model: String? = nil,
                      extraTopLevel: [String: Any] = [:], extraTokenKey: [String: Any] = [:],
                      dropTokenKey: String? = nil) -> Data {
        var tokens: [String: Any] = ["input": tokensInput, "output": 0, "cacheRead": 0,
                                     "cacheWrite5m": 0, "cacheWrite1h": 0, "cacheWriteUnknown": 0]
        if let dropTokenKey { tokens.removeValue(forKey: dropTokenKey) }
        for (k, v) in extraTokenKey { tokens[k] = v }
        var obj: [String: Any] = ["id": id, "providerId": provider, "timestamp": ts,
                                  "tokens": tokens, "sourceKind": "mx"]
        if let model { obj["modelId"] = model }
        for (k, v) in extraTopLevel { obj[k] = v }
        var data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func blob(_ parts: [Data]) -> Data {
        var d = Data(); for p in parts { d.append(p) }; return d
    }

    /// O1 + O2 一體斷言,並**釘死該向量的絕對預期判決**(`expectSuccess`)——不只驗兩形一致,也驗
    /// `canonicalizeRawLines` 本身的判決正確。回應 cross-model review(grok + Claude critic 皆指出:
    /// 原本 T1 的 valid-* 僅驗一致、未斷言 .success;共用 canonicalizeScan ⇒ shared-core 誤分類兩形都會
    /// 犯而一致性檢查看不出)。加上 expectSuccess 後,T1 不再依賴 composition 即自證絕對判決 + 等價。
    private func assertEquivalent(_ label: String, _ data: Data, expectSuccess: Bool,
                                  file: StaticString = #file, line: UInt = #line) {
        let sliceResult = CanonicalLedgerV1.canonicalizeRawLines(data)
        let validateResult = CanonicalLedgerV1.canonicalizeRawLinesValidate(data)
        switch sliceResult {
        case .success:
            XCTAssertTrue(expectSuccess, "[\(label)] 預期 .failure 卻得 .success(絕對判決錯)", file: file, line: line)
            XCTAssertNil(validateResult, "[\(label)] Slice=.success ⇒ validate 必為 nil(O1)", file: file, line: line)
        case .failure(let f2):
            XCTAssertFalse(expectSuccess, "[\(label)] 預期 .success 卻得 .failure(絕對判決錯)", file: file, line: line)
            guard let f1 = validateResult else {
                XCTAssertTrue(false, "[\(label)] Slice=.failure 但 validate=nil(O1 破)", file: file, line: line)
                return
            }
            XCTAssertEqual(f1, f2, "[\(label)] FailureSummary 必完全相等(O2)", file: file, line: line)
        }
    }

    // MARK: - T1 全向量矩陣(O1∧O2)

    func testValidateEquivalenceAcrossFullVectorMatrix() throws {
        // --- accept 向量(預期兩者 success / nil)---
        assertEquivalent("valid-single", line(id: "e1"), expectSuccess: true)
        assertEquivalent("valid-multi", blob([line(id: "a"), line(id: "b"), line(id: "c")]), expectSuccess: true)
        assertEquivalent("valid-with-model", line(id: "m1", model: "opus"), expectSuccess: true)
        assertEquivalent("valid-fractional-ts", line(id: "f1", ts: "2026-07-29T00:00:00.123Z"), expectSuccess: true)
        assertEquivalent("valid-lowercase-tz", line(id: "l1", ts: "2026-07-29t00:00:00z"), expectSuccess: true)
        assertEquivalent("empty-input", Data(), expectSuccess: true)
        assertEquivalent("trailing-newline-only-success", line(id: "t1"), expectSuccess: true)   // helper 已附單一尾端 \n
        // value 內含 key 樣式字串:不得被 scanRawMembers 誤判為重複 member。
        assertEquivalent("value-contains-key-pattern",
                         line(id: "v1", extraTopLevel: ["sourcePath": "/mx/weird\"tokens\":{\"input\":9}.jsonl"]),
                         expectSuccess: true)
        // double-backed providerCostUSD 合法(保留 raw backing;int≠double 僅在比較時)。
        assertEquivalent("double-providerCost",
                         line(id: "d1", extraTopLevel: ["providerCostUSD": 1.5]), expectSuccess: true)
        assertEquivalent("int-providerCost",
                         line(id: "d2", extraTopLevel: ["providerCostUSD": 2]), expectSuccess: true)

        // --- reject 向量:schema ---
        for missing in ["id", "providerId", "timestamp", "tokens", "sourceKind"] {
            var obj: [String: Any] = ["id": "x", "providerId": "p", "timestamp": "2026-07-29T00:00:00Z",
                                      "tokens": ["input": 1, "output": 0, "cacheRead": 0,
                                                 "cacheWrite5m": 0, "cacheWrite1h": 0], "sourceKind": "k"]
            obj.removeValue(forKey: missing)
            var d = try JSONSerialization.data(withJSONObject: obj); d.append(0x0A)
            assertEquivalent("missing-\(missing)", d, expectSuccess: false)
        }
        assertEquivalent("not-json", Data("not json\n".utf8), expectSuccess: false)
        assertEquivalent("non-object-array", Data("[1,2]\n".utf8), expectSuccess: false)
        // 空 id(invalidTypes)。
        let emptyID = Data(String(data: line(id: "e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"id\":\"e1\"", with: "\"id\":\"\"").utf8)
        assertEquivalent("empty-id", emptyID, expectSuccess: false)
        // 內部空白行(malformed,不得靜默跳過)。
        var withBlank = line(id: "e1"); withBlank.append(0x0A); withBlank.append(line(id: "e2"))
        assertEquivalent("internal-blank-line", withBlank, expectSuccess: false)
        assertEquivalent("whitespace-only", Data("   \n".utf8), expectSuccess: false)
        assertEquivalent("newline-only", Data("\n".utf8), expectSuccess: false)
        // unknown top-level / token key。
        assertEquivalent("unknown-top-key", line(id: "u1", extraTopLevel: ["bogusKey": "x"]), expectSuccess: false)
        assertEquivalent("unknown-token-key", line(id: "u2", extraTokenKey: ["bogusTok": 1]), expectSuccess: false)
        // bool / double token(型別偏差 fail closed)。
        assertEquivalent("bool-token", line(id: "b1", extraTokenKey: ["input": true]), expectSuccess: false)
        assertEquivalent("double-token", line(id: "b2", extraTokenKey: ["input": 1.5]), expectSuccess: false)
        // unsigned 超界 token(窄化有損 fail closed)。
        let overflow = Data(("{\"id\":\"o1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":18446744073709551615,\"output\":0,\"cacheRead\":0," +
            "\"cacheWrite5m\":0,\"cacheWrite1h\":0},\"sourceKind\":\"k\"}\n").utf8)
        assertEquivalent("unsigned-overflow-token", overflow, expectSuccess: false)

        // --- reject 向量:raw-byte(dup member / escaped key)---
        let dupMember = Data(("{\"id\":\"e1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":1,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"tokens\":{\"input\":2,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"sourceKind\":\"k\"}\n").utf8)
        assertEquivalent("dup-member", dupMember, expectSuccess: false)
        let spacedDup = Data(String(data: dupMember, encoding: .utf8)!
            .replacingOccurrences(of: "\"tokens\":{\"input\":2", with: "\"tokens\" :{\"input\":2").utf8)
        assertEquivalent("spaced-dup-member", spacedDup, expectSuccess: false)
        let aliasDup = Data(("{\"id\":\"e1\",\"\\u0069d\":\"e2\",\"providerId\":\"p\"," +
            "\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":1,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"sourceKind\":\"k\"}\n").utf8)
        assertEquivalent("escaped-alias-id", aliasDup, expectSuccess: false)
        let escTokens = Data(("{\"id\":\"e1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"\\u0074okens\":{\"input\":1,\"input\":2,\"output\":0,\"cacheRead\":0," +
            "\"cacheWrite5m\":0,\"cacheWrite1h\":0},\"sourceKind\":\"k\"}\n").utf8)
        assertEquivalent("escaped-tokens-alias", escTokens, expectSuccess: false)
        let loneEsc = Data(String(data: line(id: "e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"sourceKind\":", with: "\"sourceKin\\u0064\":").utf8)
        assertEquivalent("lone-escaped-key", loneEsc, expectSuccess: false)
    }

    // MARK: - T2 duplicate IDs

    func testValidateEquivalenceDuplicateIDs() throws {
        let dup = blob([line(id: "same"), line(id: "same"), line(id: "other")])
        // Slice-form 必 .failure(duplicateIDs)。
        guard case .failure(let f2) = CanonicalLedgerV1.canonicalizeRawLines(dup) else {
            XCTAssertTrue(false, "重複 id 必 .failure"); return
        }
        guard let f1 = CanonicalLedgerV1.canonicalizeRawLinesValidate(dup) else {
            XCTAssertTrue(false, "重複 id 的 validate 必非 nil"); return
        }
        XCTAssertEqual(f1, f2, "duplicateIDs 計數與整體 FailureSummary 必相等")
        XCTAssertTrue(f1.duplicateIDs >= 2, "兩筆同 id ⇒ duplicateIDs >= 2(實得 \(f1.duplicateIDs))")
    }

    // MARK: - T3 encoding gates(固定優先序 BOM > NUL > invalid-UTF-8)

    func testValidateEquivalenceEncodingGates() throws {
        // UTF-8 BOM 前綴 + 否則合法的一行。
        var bom = Data([0xEF, 0xBB, 0xBF]); bom.append(line(id: "e1"))
        assertEquivalent("bom-prefix", bom, expectSuccess: false)
        // 內嵌 NUL。
        var nul = line(id: "e1"); nul.insert(0x00, at: nul.count / 2)
        assertEquivalent("embedded-nul", nul, expectSuccess: false)
        // 非法 UTF-8 序列(0xC2 lead 後接 LF:整檔 UTF-8 驗證必拒)。
        let badUTF8 = Data([0xC2, 0x0A])
        assertEquivalent("invalid-utf8", badUTF8, expectSuccess: false)
        // 明確檢查固定優先序:BOM+NUL 同在 ⇒ 只記 bomCount(BOM 優先)。
        var bomAndNul = Data([0xEF, 0xBB, 0xBF, 0x00]); bomAndNul.append(line(id: "e1"))
        guard let fv = CanonicalLedgerV1.canonicalizeRawLinesValidate(bomAndNul),
              case .failure(let fs) = CanonicalLedgerV1.canonicalizeRawLines(bomAndNul) else {
            XCTAssertTrue(false, "BOM+NUL 必失敗"); return
        }
        XCTAssertEqual(fv, fs, "BOM+NUL 的 FailureSummary 必相等")
        XCTAssertEqual(fv.bomCount, 1, "BOM 優先:bomCount==1")
        XCTAssertEqual(fv.nulByteCount, 0, "BOM 優先於 NUL:不另記 nulByteCount")
    }

    // MARK: - T4 大型乾淨帳本(success-path parity)

    func testValidateEquivalenceOnRealLedgerShape() throws {
        let models = ["opus", "sonnet", "haiku", "grok", "gpt"]
        var parts: [Data] = []
        for i in 0..<2000 {
            let ts = "2026-07-\(String(format: "%02d", (i % 28) + 1))T\(String(format: "%02d", i % 24)):00:00Z"
            parts.append(line(id: "evt-\(i)", provider: "p\(i % 4)", ts: ts, tokensInput: i,
                              model: models[i % models.count],
                              extraTopLevel: ["projectId": "proj-\(i % 7)", "providerCostUSD": Double(i) * 0.001]))
        }
        let big = blob(parts)
        guard case .success(let slice) = CanonicalLedgerV1.canonicalizeRawLines(big) else {
            XCTAssertTrue(false, "2000 筆乾淨事件必 .success"); return
        }
        XCTAssertEqual(slice.count, 2000, "distinct id 計數應為 2000")
        XCTAssertNil(CanonicalLedgerV1.canonicalizeRawLinesValidate(big),
                     "同一乾淨帳本 validate 必為 nil(success-path parity)")
    }

    // MARK: - T5 compaction guard fail-closed 決策(item 8)

    func testCompactionGuardFailClosedOnSuspectRaw() throws {
        // coordinator 的 guard 做的正是 `canonicalizeRawLinesValidate(raw) == nil`:
        //   乾淨 raw ⇒ nil ⇒ compaction 可進行;可疑 raw ⇒ 非 nil ⇒ 必跳過(fail closed)。
        let clean = blob([line(id: "a"), line(id: "b")])
        XCTAssertNil(CanonicalLedgerV1.canonicalizeRawLinesValidate(clean),
                     "乾淨 raw:guard 放行(== nil)")
        let unknownKey = line(id: "x", extraTopLevel: ["evil": "1"])
        XCTAssertNotNil(CanonicalLedgerV1.canonicalizeRawLinesValidate(unknownKey),
                        "unknown-key raw:guard 必 fail closed(!= nil)⇒ compaction 跳過")
        let dupID = blob([line(id: "same"), line(id: "same")])
        XCTAssertNotNil(CanonicalLedgerV1.canonicalizeRawLinesValidate(dupID),
                        "dup-id raw:guard 必 fail closed")
        var nul = line(id: "x"); nul.insert(0x00, at: 3)
        XCTAssertNotNil(CanonicalLedgerV1.canonicalizeRawLinesValidate(nul),
                        "NUL raw:guard 必 fail closed")
    }

    // MARK: - T6 Slice-form 內容未受擾(gate / canonicalizePersistedBytes 消費者)

    func testSliceFormUnchangedRegressionSpotCheck() throws {
        let data = blob([line(id: "e1", tokensInput: 100, model: "opus"),
                         line(id: "e2", tokensInput: 42)])
        guard case .success(let slice) = CanonicalLedgerV1.canonicalizeRawLines(data) else {
            XCTAssertTrue(false, "合法行必 .success"); return
        }
        XCTAssertEqual(slice.count, 2)
        XCTAssertEqual(slice.events["e1"]?.fields["tokens.input"], .int(100))
        XCTAssertEqual(slice.events["e1"]?.fields["modelId"], .string("opus"))
        XCTAssertEqual(slice.events["e2"]?.fields["tokens.input"], .int(42))
        XCTAssertEqual(slice.events["e2"]?.fields["modelId"], .null, "缺 modelId ⇒ .null(N2)")
    }

    // MARK: - T7 compactRawPreserving defensive fail-closed on unparseable raw
    // (pins the Option C autoreleasepool-restructured pass-2:解析失敗 ⇒ .failParse ⇒ .failed,不改寫原檔。
    //  此 defensive 路在 coordinator 不可達(上游 guard 先拒),原碼亦無覆蓋 — 本測試一併補上 defense-in-depth。)

    func testCompactRawPreservingFailsClosedOnUnparseableRaw() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p2-failclosed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.jsonl")
        let enc = AtomicJSON.encoder()
        let now = Date()
        let expired = UsageEvent(id: "old", providerId: "p", timestamp: now.addingTimeInterval(-200 * 86400),
                                 tokens: TokenBreakdown(input: 1), sourceKind: "t")
        let kept = UsageEvent(id: "new", providerId: "p", timestamp: now.addingTimeInterval(-60),
                              tokens: TokenBreakdown(input: 1), sourceKind: "t")
        var clean = Data()
        clean.append(try enc.encode(expired)); clean.append(0x0A)
        clean.append(try enc.encode(kept)); clean.append(0x0A)
        try clean.write(to: url)
        let ledger = UsageLedger(fileURL: url)
        XCTAssertNil(ledger.loadError, "乾淨檔必須正常載入")
        // 不可解析的 raw:在過期行後插入一行 "not json"。
        var malformed = Data()
        malformed.append(try enc.encode(expired)); malformed.append(0x0A)
        malformed.append(Data("not json\n".utf8))
        malformed.append(try enc.encode(kept)); malformed.append(0x0A)
        let result = ledger.compactRawPreserving(retentionDays: 92, now: now, raw: malformed)
        XCTAssertEqual(result, .failed, "raw 含不可解析行 ⇒ compactRawPreserving 必 fail closed(.failed)")
        XCTAssertEqual(try Data(contentsOf: url), clean, "失敗時原檔逐位元組保留(不改寫)")
    }
}
