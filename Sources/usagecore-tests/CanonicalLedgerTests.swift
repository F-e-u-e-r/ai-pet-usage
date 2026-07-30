import Foundation
import UsageCore

// CanonicalLedgerV1 stage-acceptance(owner 2026-07-30 裁決的八類)。
// 本 suite 全綠 = canonicalizer 階段驗收;矩陣的 history-loss RED 案例仍必須維持紅燈
// (gate 未接線——本階段不實作 CAS/replacement gate)。

private func clLine(_ id: String, tokensInput: Int = 100, model: String? = nil,
                    ts: String = "2026-07-29T00:00:00Z", extraTopLevel: [String: Any] = [:],
                    dropTokenKey: String? = nil, extraTokenKey: [String: Any] = [:]) -> Data {
    var tokens: [String: Any] = ["input": tokensInput, "output": 0, "cacheRead": 0,
                                 "cacheWrite5m": 0, "cacheWrite1h": 0, "cacheWriteUnknown": 0]
    if let dropTokenKey { tokens.removeValue(forKey: dropTokenKey) }
    for (k, v) in extraTokenKey { tokens[k] = v }
    var obj: [String: Any] = ["id": id, "providerId": "mx", "timestamp": ts,
                              "tokens": tokens, "sourceKind": "mx"]
    if let model { obj["modelId"] = model }
    for (k, v) in extraTopLevel { obj[k] = v }
    var data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    data.append(0x0A)
    return data
}

private func clSlice(_ lines: [Data]) -> Result<CanonicalLedgerV1.Slice, CanonicalLedgerV1.FailureSummary> {
    var blob = Data()
    for l in lines { blob.append(l) }
    return CanonicalLedgerV1.canonicalizeRawLines(blob)
}

final class CanonicalLedgerTests: XCTestCase {

    // 1) raw-key/schema:合法行成功;缺 required key 失敗且 key 名入摘要;
    //    malformed/非物件/空 id/空白行/同行重複 member 全部 fail closed。
    func testSchemaValidLineAndMissingRequiredKeys() throws {
        guard case .success(let ok) = clSlice([clLine("e1")]) else {
            XCTAssertTrue(false, "合法行必須 canonicalize 成功"); return
        }
        XCTAssertEqual(ok.count, 1)
        XCTAssertEqual(ok.events["e1"]?.fields["tokens.input"], .int(100))
        for missing in ["id", "providerId", "timestamp", "tokens", "sourceKind"] {
            var obj: [String: Any] = ["id": "x", "providerId": "p",
                                      "timestamp": "2026-07-29T00:00:00Z",
                                      "tokens": ["input": 1, "output": 0, "cacheRead": 0,
                                                 "cacheWrite5m": 0, "cacheWrite1h": 0],
                                      "sourceKind": "k"]
            obj.removeValue(forKey: missing)
            var data = try JSONSerialization.data(withJSONObject: obj)
            data.append(0x0A)
            guard case .failure(let f) = CanonicalLedgerV1.canonicalizeRawLines(data) else {
                XCTAssertTrue(false, "缺 \(missing) 必須失敗"); continue
            }
            XCTAssertTrue(f.missingRequiredKeys > 0, "缺 \(missing) 計入 missingRequiredKeys")
            XCTAssertTrue(f.offendingKeys.contains(missing),
                          "摘要含 key 名 \(missing)(封閉集 schema 詞彙;不得靠逃逸條件假通過)")
        }
        // malformed / 非物件行。
        guard case .failure(let fm) = CanonicalLedgerV1.canonicalizeRawLines(Data("not json\n".utf8)),
              fm.malformedLines == 1 else { XCTAssertTrue(false, "malformed 行必須失敗"); return }
        guard case .failure(let fa) = CanonicalLedgerV1.canonicalizeRawLines(Data("[1,2]\n".utf8)),
              fa.malformedLines == 1 else { XCTAssertTrue(false, "非物件行必須失敗"); return }
        // 空 id。
        var emptyID = clLine("e1")
        emptyID = Data(String(data: emptyID, encoding: .utf8)!
            .replacingOccurrences(of: "\"id\":\"e1\"", with: "\"id\":\"\"").utf8)
        guard case .failure(let fe) = CanonicalLedgerV1.canonicalizeRawLines(emptyID),
              fe.invalidTypes > 0 else { XCTAssertTrue(false, "空 id 必須失敗"); return }
        // 空白行:單一 trailing newline 合法;內部空白行 malformed(impl-r1 L1)。
        guard case .success = clSlice([clLine("e1")]) else { XCTAssertTrue(false); return }
        var withBlank = clLine("e1")
        withBlank.append(0x0A)                       // 造成連續 newline(內部空段)
        withBlank.append(clLine("e2"))
        guard case .failure(let fb) = CanonicalLedgerV1.canonicalizeRawLines(withBlank),
              fb.malformedLines == 1 else {
            XCTAssertTrue(false, "內部空白行不得被靜默跳過(未列舉 normalization)"); return
        }
        // 同行重複 schema member:JSONSerialization 會塌縮,必須在 raw byte 層攔截(impl-r1 L2)。
        let dupMember = Data(("{" +
            "\"id\":\"e1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":1,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"tokens\":{\"input\":2,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"sourceKind\":\"k\"}\n").utf8)
        guard case .failure(let fd) = CanonicalLedgerV1.canonicalizeRawLines(dupMember),
              fd.duplicateJSONMembers == 1 else {
            XCTAssertTrue(false, "同行重複 member 必須 fail closed"); return
        }
        // impl-r2:帶空白的重複 member(`"tokens" :`)同樣必須被抓(string-aware 掃描)。
        let spacedDup = Data(String(data: dupMember, encoding: .utf8)!
            .replacingOccurrences(of: "\"tokens\":{\"input\":2", with: "\"tokens\" :{\"input\":2").utf8)
        guard case .failure(let fs) = CanonicalLedgerV1.canonicalizeRawLines(spacedDup),
              fs.duplicateJSONMembers == 1 else {
            XCTAssertTrue(false, "空白形式重複 member 不得 fail-open"); return
        }
        // impl-r2:字串「值」內含 key 樣式(含跳脫引號)不得假陽性。
        guard case .success = clSlice([clLine("e1", extraTopLevel:
            ["sourcePath": "/mx/weird\"tokens\":{\"input\":9}.jsonl"])]) else {
            XCTAssertTrue(false, "值內容含 key 樣式不得誤判為重複 member"); return
        }
        // impl-r3(三 lens 收斂 MUST-FIX):跳脫別名 key 一律 fail closed——
        // (a) `"id"` 與 `"id"` 並存(JSONSerialization 會解碼塌縮,掃描層看不見);
        let aliasDup = Data(("{" +
            "\"id\":\"e1\",\"\\u0069d\":\"e2\",\"providerId\":\"p\"," +
            "\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":1,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"sourceKind\":\"k\"}\n").utf8)
        guard case .failure(let fa2) = CanonicalLedgerV1.canonicalizeRawLines(aliasDup),
              fa2.escapedKeyNames == 1 else {
            XCTAssertTrue(false, "跳脫別名 key(\\u0069d)必須 fail closed"); return
        }
        // (b) sol 的攻擊鏈:`"tokens"` 令 pendingTokensObject 永不設旗、藏內部重複 input。
        let escTokens = Data(("{" +
            "\"id\":\"e1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"\\u0074okens\":{\"input\":1,\"input\":2,\"output\":0,\"cacheRead\":0," +
            "\"cacheWrite5m\":0,\"cacheWrite1h\":0},\"sourceKind\":\"k\"}\n").utf8)
        guard case .failure(let fe2) = CanonicalLedgerV1.canonicalizeRawLines(escTokens),
              fe2.escapedKeyNames == 1 else {
            XCTAssertTrue(false, "跳脫 tokens key 藏內部重複必須 fail closed"); return
        }
        // (c) 即使無重複,單獨的 escaped key 也 fail closed(嚴格規則:schema key 永無跳脫)。
        let loneEsc = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"sourceKind\":", with: "\"sourceKin\\u0064\":").utf8)
        guard case .failure(let fl2) = CanonicalLedgerV1.canonicalizeRawLines(loneEsc),
              fl2.escapedKeyNames == 1 else {
            XCTAssertTrue(false, "任何 escaped key 皆 fail closed(不需伴隨重複)"); return
        }
        // impl-r2:空輸入=合法空 slice;全空白行與 newline-only 皆 fail closed。
        guard case .success(let empty) = CanonicalLedgerV1.canonicalizeRawLines(Data()),
              empty.count == 0 else { XCTAssertTrue(false, "空輸入必須是合法空 slice"); return }
        guard case .failure = CanonicalLedgerV1.canonicalizeRawLines(Data("   \n".utf8)) else {
            XCTAssertTrue(false, "全空白行必須失敗"); return
        }
        guard case .failure(let fn) = CanonicalLedgerV1.canonicalizeRawLines(Data("\n".utf8)),
              fn.malformedLines == 1 else {
            XCTAssertTrue(false, "newline-only 必須失敗(非 trailing:無任何內容行)"); return
        }
    }

    // 2) absent/null/zero normalization:N1 cacheWriteUnknown absent≡0;N2 modelId absent≡null;
    //    其餘 token 欄位 absent ⇒ fail;required key explicit null ⇒ fail。
    func testAbsentNullZeroNormalization() throws {
        guard case .success(let a) = clSlice([clLine("e1", dropTokenKey: "cacheWriteUnknown")]),
              case .success(let b) = clSlice([clLine("e1")]) else {
            XCTAssertTrue(false, "N1 兩形都必須成功"); return
        }
        XCTAssertEqual(a.events["e1"], b.events["e1"], "N1:cacheWriteUnknown absent ≡ explicit 0")

        guard case .success(let noModel) = clSlice([clLine("e1")]),
              case .success(let nullModel) = clSlice([clLine("e1", extraTopLevel: ["modelId": NSNull()])]) else {
            XCTAssertTrue(false, "N2 兩形都必須成功"); return
        }
        XCTAssertEqual(noModel.events["e1"], nullModel.events["e1"], "N2:modelId absent ≡ explicit null")

        guard case .failure(let f1) = clSlice([clLine("e1", dropTokenKey: "input")]) else {
            XCTAssertTrue(false, "tokens.input absent 不在 normalization 清單 ⇒ 必須失敗"); return
        }
        XCTAssertTrue(f1.offendingKeys.contains("tokens.input"))

        guard case .failure(_) = clSlice([clLine("e1", extraTopLevel: ["providerId": NSNull()])]) else {
            XCTAssertTrue(false, "required key explicit null ⇒ 必須失敗"); return
        }

        // absent(→N1 的 0)與 explicit 非零值不等義。
        guard case .success(let z) = clSlice([clLine("e1", extraTokenKey: ["cacheWriteUnknown": 7])]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertTrue(a.events["e1"] != z.events["e1"], "absent≡0 ≠ explicit 7")
    }

    // 3) duplicate 偵測(兩側、先於任何 keep-first):同 ID 兩行 ⇒ failure,絕不回傳去重後 slice。
    func testDuplicateIDsFailBothSidesBeforeAnyOverwrite() throws {
        guard case .failure(let f) = clSlice([clLine("dup", tokensInput: 100),
                                              clLine("dup", tokensInput: 200)]) else {
            XCTAssertTrue(false, "baseline duplicate 必須 fail closed(不得 keep-first)"); return
        }
        XCTAssertEqual(f.duplicateIDs, 2, "duplicate 計數為出現次數")
        // candidate 側(persisted-bytes 路徑)同樣 fail。
        let ts = Date(timeIntervalSince1970: 1_753_000_000)
        let ev = { UsageEvent(id: "dup", providerId: "mx", timestamp: ts,
                              tokens: TokenBreakdown(input: $0), sourceKind: "mx") }
        guard case .failure(let f2) = CanonicalLedgerV1.canonicalizePersistedBytes(of: [ev(1), ev(2)]) else {
            XCTAssertTrue(false, "candidate duplicate 必須 fail closed"); return
        }
        XCTAssertEqual(f2.duplicateIDs, 2)
    }

    // 4) unknown key fail-closed:top-level 與 tokens 子層以**固定分類計數**呈現;
    //    攻擊者可控的 key 名與 payload 值都不得出現在任何公開面(owner 裁定)。
    func testUnknownKeysFailClosed() throws {
        guard case .failure(let f) = clSlice([clLine("e1", extraTopLevel: ["attacker.supplied.path": "keep-me"])]) else {
            XCTAssertTrue(false, "unknown top-level key 必須失敗"); return
        }
        XCTAssertEqual(f.unknownTopLevelKeys, 1, "固定分類計數")
        let surface = f.offendingKeys.joined()
        XCTAssertFalse(surface.contains("attacker"), "攻擊者 key 名不得外帶")
        XCTAssertFalse(surface.contains("keep-me"), "payload 值不得外帶")
        guard case .failure(let f2) = clSlice([clLine("e1", extraTokenKey: ["cacheWrite2h": 1])]) else {
            XCTAssertTrue(false, "unknown token key 必須失敗"); return
        }
        XCTAssertEqual(f2.unknownTokenKeys, 1, "token 層固定分類計數")
        XCTAssertFalse(f2.offendingKeys.joined().contains("cacheWrite2h"), "未知 token key 名同樣不外帶")
    }

    // 4b) 數值窄化與型別形式(impl-r1 L3/L4):cost int-backed ≠ double-backed;
    //     unsigned 超出 Int64.max 的 token ⇒ fail closed;cost absent/0/0.0 三分。
    func testNumberBackingAndRangeFailClosed() throws {
        guard case .success(let intCost) = clSlice([clLine("e1", extraTopLevel: ["providerCostUSD": 1])]),
              case .success(let dblCost) = CanonicalLedgerV1.canonicalizeRawLines(
                Data(String(data: clLine("e1", extraTopLevel: ["providerCostUSD": 1]), encoding: .utf8)!
                    .replacingOccurrences(of: "\"providerCostUSD\":1", with: "\"providerCostUSD\":1.0").utf8)),
              case .success(let absent) = clSlice([clLine("e1")]) else {
            XCTAssertTrue(false, "cost 三形都必須可 canonicalize"); return
        }
        XCTAssertTrue(intCost.events["e1"] != dblCost.events["e1"],
                      "cost `1`(int-backed)≠ `1.0`(double-backed)——無型別形式等義")
        XCTAssertTrue(absent.events["e1"] != intCost.events["e1"], "absent(null)≠ explicit 1")
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: intCost, candidate: dblCost),
                       .fail(missingEvents: 0, changedEvents: 1), "異形 cost ⇒ changed ⇒ preserve")
        // 2^53 精度懸崖不再塌縮:int-backed 巨值以 Int64 精確保存。
        let big1 = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"sourceKind\":\"mx\"",
                                  with: "\"sourceKind\":\"mx\",\"providerCostUSD\":9007199254740993").utf8)
        let big2 = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"sourceKind\":\"mx\"",
                                  with: "\"sourceKind\":\"mx\",\"providerCostUSD\":9007199254740992").utf8)
        guard case .success(let s1) = CanonicalLedgerV1.canonicalizeRawLines(big1),
              case .success(let s2) = CanonicalLedgerV1.canonicalizeRawLines(big2) else {
            XCTAssertTrue(false); return
        }
        XCTAssertTrue(s1.events["e1"] != s2.events["e1"], "相鄰巨整數 cost 不得因 double 化而假相等")
        // unsigned 超界 token ⇒ invalidType fail closed(impl-r1 L4)。
        let huge = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"input\":100", with: "\"input\":18446744073709551615").utf8)
        guard case .failure(let fh) = CanonicalLedgerV1.canonicalizeRawLines(huge),
              fh.invalidTypes > 0 else {
            XCTAssertTrue(false, "超出 Int64.max 的 unsigned token 必須 fail closed"); return
        }
        XCTAssertTrue(fh.offendingKeys.contains("tokens.input"))
        // bool 與 double-backed token 也 fail closed。
        let boolTok = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"input\":100", with: "\"input\":true").utf8)
        guard case .failure = CanonicalLedgerV1.canonicalizeRawLines(boolTok) else {
            XCTAssertTrue(false, "bool token 必須失敗"); return
        }
        let dblTok = Data(String(data: clLine("e1"), encoding: .utf8)!
            .replacingOccurrences(of: "\"input\":100", with: "\"input\":100.0").utf8)
        guard case .failure = CanonicalLedgerV1.canonicalizeRawLines(dblTok) else {
            XCTAssertTrue(false, "double-backed token 必須失敗"); return
        }
        // impl-r2:cost `0`(int-backed)與 `0.0`(double-backed)同樣不等義。
        guard case .success(let z0) = clSlice([clLine("e1", extraTopLevel: ["providerCostUSD": 0])]),
              case .success(let z0d) = CanonicalLedgerV1.canonicalizeRawLines(
                Data(String(data: clLine("e1", extraTopLevel: ["providerCostUSD": 0]), encoding: .utf8)!
                    .replacingOccurrences(of: "\"providerCostUSD\":0", with: "\"providerCostUSD\":0.0").utf8)) else {
            XCTAssertTrue(false); return
        }
        XCTAssertTrue(z0.events["e1"] != z0d.events["e1"], "cost `0` ≠ `0.0`(backing type 保留)")
    }

    // 5) immutable-field mutation ⇒ fail(changed 計數;token/timestamp/known→known/known→nil/sourcePath 移除)。
    func testImmutableFieldMutationsFail() throws {
        guard case .success(let base) = clSlice([clLine("e1", tokensInput: 100, model: "m-one",
                                                        extraTopLevel: ["sourcePath": "/mx/s.jsonl"])]) else {
            XCTAssertTrue(false); return
        }
        func verdict(_ lines: [Data]) -> CanonicalLedgerV1.Verdict {
            guard case .success(let cand) = clSlice(lines) else {
                XCTAssertTrue(false, "candidate 本身必須可 canonicalize"); return .fail(missingEvents: -1, changedEvents: -1)
            }
            return CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: cand)
        }
        XCTAssertEqual(verdict([clLine("e1", tokensInput: 999, model: "m-one",
                                       extraTopLevel: ["sourcePath": "/mx/s.jsonl"])]),
                       .fail(missingEvents: 0, changedEvents: 1), "token 變更 ⇒ changed")
        XCTAssertEqual(verdict([clLine("e1", tokensInput: 100, model: "m-one",
                                       ts: "2026-07-29T00:00:01Z",
                                       extraTopLevel: ["sourcePath": "/mx/s.jsonl"])]),
                       .fail(missingEvents: 0, changedEvents: 1), "timestamp 變更 ⇒ changed(N3 原字串比較)")
        XCTAssertEqual(verdict([clLine("e1", tokensInput: 100, model: "m-two",
                                       extraTopLevel: ["sourcePath": "/mx/s.jsonl"])]),
                       .fail(missingEvents: 0, changedEvents: 1), "known→known model ⇒ changed")
        XCTAssertEqual(verdict([clLine("e1", tokensInput: 100,
                                       extraTopLevel: ["sourcePath": "/mx/s.jsonl"])]),
                       .fail(missingEvents: 0, changedEvents: 1), "known→nil model ⇒ changed")
        XCTAssertEqual(verdict([clLine("e1", tokensInput: 100, model: "m-one")]),
                       .fail(missingEvents: 0, changedEvents: 1), "sourcePath 移除 ⇒ changed")
        XCTAssertEqual(verdict([]), .fail(missingEvents: 1, changedEvents: 0), "candidate 缺事件 ⇒ missing")
    }

    // 6) allowlisted enrichment:modelId absent/null→known 且其餘全等 ⇒ pass(enriched=1)。
    func testAllowlistedModelEnrichmentPasses() throws {
        guard case .success(let base) = clSlice([clLine("e1")]),
              case .success(let cand) = clSlice([clLine("e1", model: "m-known")]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: cand),
                       .pass(newEvents: 0, enrichedEvents: 1))
        guard case .success(let baseNull) = clSlice([clLine("e1", extraTopLevel: ["modelId": NSNull()])]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: baseNull, candidate: cand),
                       .pass(newEvents: 0, enrichedEvents: 1), "explicit null→known 同樣是 E1")
        // enrichment + 其他欄位變更 ⇒ 仍 fail。
        guard case .success(let candBad) = clSlice([clLine("e1", tokensInput: 999, model: "m-known")]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: candBad),
                       .fail(missingEvents: 0, changedEvents: 1))
        // 超集合 + enrichment 混合。
        guard case .success(let candSuper) = clSlice([clLine("e1", model: "m-known"), clLine("e2")]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: candSuper),
                       .pass(newEvents: 1, enrichedEvents: 1))
        // owner 裁定:空字串不是 known model,不得成為 E1 target。
        guard case .success(let candEmpty) = clSlice([clLine("e1", model: "")]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: candEmpty),
                       .fail(missingEvents: 0, changedEvents: 1), "`\"\"` = invalid/unknown ⇒ changed")
        // 多事件混合計數:兩筆 enriched + 一筆 changed ⇒ fail(changed=1)。
        guard case .success(let mb) = clSlice([clLine("a"), clLine("b"), clLine("c", tokensInput: 5)]),
              case .success(let mc) = clSlice([clLine("a", model: "m1"), clLine("b", model: "m2"),
                                               clLine("c", tokensInput: 6)]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: mb, candidate: mc),
                       .fail(missingEvents: 0, changedEvents: 1), "enriched 不得掩蓋同批 changed")
    }

    // 5b) 其餘 identity/optional 欄位的 immutability(impl-r1 L10 缺口):providerCostUSD、accountId。
    func testOptionalFieldMutationsFail() throws {
        guard case .success(let base) = clSlice([clLine("e1", extraTopLevel:
            ["providerCostUSD": 1, "accountId": "acct-A"])]) else { XCTAssertTrue(false); return }
        guard case .success(let costDrift) = clSlice([clLine("e1", extraTopLevel:
            ["providerCostUSD": 2, "accountId": "acct-A"])]) else { XCTAssertTrue(false); return }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: costDrift),
                       .fail(missingEvents: 0, changedEvents: 1), "providerCostUSD 變更 ⇒ changed")
        guard case .success(let acctDrift) = clSlice([clLine("e1", extraTopLevel:
            ["providerCostUSD": 1, "accountId": "acct-B"])]) else { XCTAssertTrue(false); return }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: acctDrift),
                       .fail(missingEvents: 0, changedEvents: 1), "accountId 變更 ⇒ changed")
        guard case .success(let acctDrop) = clSlice([clLine("e1", extraTopLevel:
            ["providerCostUSD": 1])]) else { XCTAssertTrue(false); return }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: base, candidate: acctDrop),
                       .fail(missingEvents: 0, changedEvents: 1), "known accountId 退回 absent ⇒ changed")
    }

    // 7) candidate persisted-byte canonicalization(req 12):typed event 經 production encoder 的
    //    bytes 與等價 raw 行 canonical 相等;此路徑產不出 unknown key。
    func testCandidatePersistedByteCanonicalization() throws {
        let ts = ISO8601.parse("2026-07-29T00:00:00Z")!
        let ev = UsageEvent(id: "e1", providerId: "mx", timestamp: ts,
                            tokens: TokenBreakdown(input: 100), sourceKind: "mx")
        guard case .success(let fromTyped) = CanonicalLedgerV1.canonicalizePersistedBytes(of: [ev]) else {
            XCTAssertTrue(false, "persisted-bytes 路徑必須成功"); return
        }
        guard case .success(let fromRaw) = clSlice([clLine("e1")]) else {
            XCTAssertTrue(false); return
        }
        XCTAssertEqual(fromTyped.events["e1"], fromRaw.events["e1"],
                       "typed→encoder→raw 與 hand-built raw 行 canonical 相等(同一規則、同一路徑)")
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: fromRaw, candidate: fromTyped),
                       .pass(newEvents: 0, enrichedEvents: 0))
        // impl-r1 L10:小數秒 Date + optional 欄位齊備的事件——encoder 產物必須可 canonicalize;
        // 與帶小數秒字串的 baseline raw 行比較必須 fail closed(N3 無正規化),不得在 typed 層被掩蓋。
        let fracTS = Date(timeIntervalSince1970: 1_753_000_000.5)
        let rich = UsageEvent(id: "e9", providerId: "mx", accountId: "acct-A",
                              modelId: "m-one", timestamp: fracTS,
                              tokens: TokenBreakdown(input: 1), sourceKind: "mx",
                              sourcePath: "/mx/s.jsonl", providerCostUSD: 0.25)
        guard case .success(let richSlice) = CanonicalLedgerV1.canonicalizePersistedBytes(of: [rich]) else {
            XCTAssertTrue(false, "optional 欄位齊備 + 小數秒 Date 必須可走 persisted-bytes 路徑"); return
        }
        guard case .string(let encodedTS)? = richSlice.events["e9"]?.fields["timestamp"] else {
            XCTAssertTrue(false); return
        }
        XCTAssertFalse(encodedTS.contains("."), "production encoder(.iso8601)輸出無小數秒")
        // 1_753_000_000 = 2025-07-20T08:26:40Z:baseline 與 encoder 產物**只**差小數秒表示
        // (impl-r2 luna SHOULD:先前 fixture 年份寫錯,比對因年份就失敗,對小數秒不具鑑別力)。
        XCTAssertEqual(encodedTS, "2025-07-20T08:26:40Z", "fixture 前提:encoder 產物為此整秒字串")
        let fracBaseline = Data(("{" +
            "\"accountId\":\"acct-A\",\"id\":\"e9\",\"modelId\":\"m-one\"," +
            "\"providerCostUSD\":0.25,\"providerId\":\"mx\",\"sourceKind\":\"mx\"," +
            "\"sourcePath\":\"\\/mx\\/s.jsonl\"," +
            "\"timestamp\":\"2025-07-20T08:26:40.500Z\"," +
            "\"tokens\":{\"cacheRead\":0,\"cacheWrite1h\":0,\"cacheWrite5m\":0," +
            "\"cacheWriteUnknown\":0,\"input\":1,\"output\":0}}\n").utf8)
        guard case .success(let fracSlice) = CanonicalLedgerV1.canonicalizeRawLines(fracBaseline) else {
            XCTAssertTrue(false, "小數秒 baseline 行本身合法"); return
        }
        XCTAssertEqual(CanonicalLedgerV1.compareMonotonic(baseline: fracSlice, candidate: richSlice),
                       .fail(missingEvents: 0, changedEvents: 1),
                       "timestamp 表示差異 ⇒ changed(fail closed),不得被等同")
    }

    // 8) 版本與規格常數凍結(比較跨時可對照;變更即 version bump)。
    func testVersionAndSpecConstantsFrozen() throws {
        XCTAssertEqual(CanonicalLedgerV1.canonicalizerVersion, 1)
        XCTAssertEqual(CanonicalLedgerV1.ledgerSchemaAssumption, "usage-event-jsonl/current")
    }

    // 9) Encoding-domain gate(owner amendment):輸入契約 = 無 BOM 嚴格 UTF-8;
    //    整份 Data 在切行/掃描/parse 前驗證;BOM > NUL > invalid-UTF-8 優先序由此鎖定。
    func testEncodingDomainGate() throws {
        // 攻擊 payload(UTF-8 原文):sol 的兩個別名 exploit。
        let aliasJSON = "{\"id\":\"e1\",\"\\u0069d\":\"e2\",\"providerId\":\"p\"," +
            "\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"tokens\":{\"input\":1,\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0}," +
            "\"sourceKind\":\"k\"}"
        let escTokensJSON = "{\"id\":\"e1\",\"providerId\":\"p\",\"timestamp\":\"2026-07-29T00:00:00Z\"," +
            "\"\\u0074okens\":{\"input\":1,\"input\":2,\"output\":0,\"cacheRead\":0," +
            "\"cacheWrite5m\":0,\"cacheWrite1h\":0},\"sourceKind\":\"k\"}"

        func expectEncodingReject(_ data: Data, bom: Int, nul: Int, inv: Int, _ label: String) {
            guard case .failure(let f) = CanonicalLedgerV1.canonicalizeRawLines(data) else {
                XCTAssertTrue(false, "\(label) 必須 fail closed"); return
            }
            XCTAssertEqual(f.bomCount, bom, "\(label) bomCount")
            XCTAssertEqual(f.nulByteCount, nul, "\(label) nulByteCount(單一分類,優先序鎖定)")
            XCTAssertEqual(f.invalidEncodingCount, inv, "\(label) invalidEncodingCount")
            XCTAssertEqual(f.malformedLines, 0, "\(label) 編碼拒絕先於切行:不得出現行級計數")
            XCTAssertEqual(f.duplicateJSONMembers + f.escapedKeyNames, 0,
                           "\(label) 編碼拒絕先於掃描:不得出現掃描級計數")
        }
        // 1) UTF-16LE 無 BOM + alias exploit → NUL 前置拒絕(BOM 不在 → NUL 優先)。
        expectEncodingReject(aliasJSON.data(using: .utf16LittleEndian)!, bom: 0, nul: 1, inv: 0, "UTF-16LE 無 BOM")
        // 2) UTF-16BE 無 BOM + container-alias exploit。
        expectEncodingReject(escTokensJSON.data(using: .utf16BigEndian)!, bom: 0, nul: 1, inv: 0, "UTF-16BE 無 BOM")
        // 3) UTF-16 有 BOM:BOM 優先於 NUL(優先序測試)。
        var u16leBOM = Data([0xFF, 0xFE]); u16leBOM.append(aliasJSON.data(using: .utf16LittleEndian)!)
        expectEncodingReject(u16leBOM, bom: 1, nul: 0, inv: 0, "UTF-16LE 有 BOM")
        var u16beBOM = Data([0xFE, 0xFF]); u16beBOM.append(aliasJSON.data(using: .utf16BigEndian)!)
        expectEncodingReject(u16beBOM, bom: 1, nul: 0, inv: 0, "UTF-16BE 有 BOM")
        // 4) UTF-32 代表案例:LE 有 BOM、BE 無 BOM。
        var u32leBOM = Data([0xFF, 0xFE, 0x00, 0x00]); u32leBOM.append(aliasJSON.data(using: .utf32LittleEndian)!)
        expectEncodingReject(u32leBOM, bom: 1, nul: 0, inv: 0, "UTF-32LE 有 BOM")
        expectEncodingReject(aliasJSON.data(using: .utf32BigEndian)!, bom: 0, nul: 1, inv: 0, "UTF-32BE 無 BOM")
        // 5) malformed / truncated UTF-8(無 BOM、無 NUL)→ 主 gate 攔截。
        var badUTF8 = clLine("e1"); badUTF8.append(contentsOf: [0xC3])          // truncated 2-byte seq
        expectEncodingReject(badUTF8, bom: 0, nul: 0, inv: 1, "truncated UTF-8")
        var strayCont = clLine("e1"); strayCont.append(contentsOf: [0x80, 0x0A]) // stray continuation
        expectEncodingReject(strayCont, bom: 0, nul: 0, inv: 1, "stray continuation byte")
        // 6) raw NUL 混入合法 UTF-8。
        var withNul = clLine("e1"); withNul.insert(0x00, at: 5)
        expectEncodingReject(withNul, bom: 0, nul: 1, inv: 0, "raw NUL")
        // 7) UTF-8 BOM 前綴。
        var u8bom = Data([0xEF, 0xBB, 0xBF]); u8bom.append(clLine("e1"))
        expectEncodingReject(u8bom, bom: 1, nul: 0, inv: 0, "UTF-8 BOM")
        // 8) 合法 BOM-less UTF-8 的 escaped-key 攻擊仍由既有規則攔截(schema test (a) 已鎖;此處覆核)。
        guard case .failure(let f8) = CanonicalLedgerV1.canonicalizeRawLines(Data((aliasJSON + "\n").utf8)),
              f8.escapedKeyNames == 1, f8.bomCount + f8.nulByteCount + f8.invalidEncodingCount == 0 else {
            XCTAssertTrue(false, "UTF-8 escaped-key 攻擊仍須由 escapedKeyNames 攔截"); return
        }
        // 9) 合法 UTF-8 value 內 escape 正常接受(既有 weird-sourcePath 案例已鎖;此處以非 ASCII 併驗)。
        // 10) 合法非 ASCII UTF-8 event 正常 canonicalize(證明是 UTF-8-only,不是 ASCII-only)。
        guard case .success(let ok) = clSlice([clLine("e1", extraTopLevel:
            ["projectName": "專案–π ✓", "sourcePath": "/mx/路徑/α.jsonl"])]) else {
            XCTAssertTrue(false, "合法非 ASCII UTF-8 不得被誤拒"); return
        }
        XCTAssertEqual(ok.events["e1"]?.fields["projectName"], .string("專案–π ✓"))
    }
}
