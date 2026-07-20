import Foundation
import UsageCore
import PetCore

// MARK: - OpenRouter credits(opt-in 監控)—— 信任邊界測試(R1 雙審 C11)
// 全部離線:key 解析、request 建構、回應解析、封閉詞彙呈現、泡泡行預算。
// 任何測試都**不得**碰真網路;request 只建構、不發送。

final class OpenRouterCreditsTests: XCTestCase {

    private func authJSON(_ body: String) -> Data { Data(body.utf8) }
    private let goodKey = "sk-or-v1-" + String(repeating: "a", count: 64)

    // MARK: Key parser(窄解碼、fail closed)

    func testKeyParserHappyPathAndForeignEntriesIgnored() {
        // 其他 provider 項目(oauth 憑證等)存在也只解 openrouter 一項。
        let data = authJSON("""
        {"anthropic":{"type":"oauth","access":"secret-a","refresh":"secret-r","expires":1},
         "openrouter":{"type":"api","key":"\(goodKey)"}}
        """)
        XCTAssertEqual(OpenRouterKeyParser.parse(data: data), goodKey)
    }

    func testKeyParserRefusals() {
        // oauth 型(非 api)→ nil
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(
            #"{"openrouter":{"type":"oauth","key":"\#(goodKey)"}}"#)))
        // 缺 openrouter 項 → nil
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(#"{"anthropic":{"type":"api","key":"x"}}"#)))
        // 空 key / 過短 / 過長 → nil
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(#"{"openrouter":{"type":"api","key":""}}"#)))
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(#"{"openrouter":{"type":"api","key":"short"}}"#)))
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(
            #"{"openrouter":{"type":"api","key":"\#(String(repeating: "k", count: 513))"}}"#)))
        // header 注入字元(CR/LF/空白)與非 ASCII → nil
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(
            "{\"openrouter\":{\"type\":\"api\",\"key\":\"sk-or-v1-aaaaaaaaaa\\r\\nHost: evil\"}}")))
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(
            #"{"openrouter":{"type":"api","key":"sk-or v1 with spaces aaaaaaaaaa"}}"#)))
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(
            #"{"openrouter":{"type":"api","key":"sk-or-v1-金鑰金鑰金鑰金鑰金鑰金鑰"}}"#)))
        // 非 JSON → nil
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON("not json at all")))
        // 超過檔案大小上限 → nil(fail closed)
        var big = "{\"openrouter\":{\"type\":\"api\",\"key\":\"\(goodKey)\"},\"pad\":\""
        big += String(repeating: "p", count: OpenRouterKeyParser.maxAuthFileBytes)
        big += "\"}"
        XCTAssertNil(OpenRouterKeyParser.parse(data: authJSON(big)))
    }

    // MARK: Request 建構(key 只進 Authorization;無 query;僅三個標頭)

    func testRequestShape() {
        let req = OpenRouterCreditsEngine.request(key: goodKey, appVersion: "1.2.3")
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
        XCTAssertNil(req.url?.query, "key 絕不得出現在 URL/query")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.timeoutInterval, 15, accuracy: 0.01)
        let headers = req.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers.count, 3, "標頭僅 Authorization/Accept/User-Agent 三項,不夾帶其他資料")
        XCTAssertEqual(headers["Authorization"], "Bearer \(goodKey)")
        XCTAssertEqual(headers["Accept"], "application/json")
        XCTAssertEqual(headers["User-Agent"], "AIPetUsage/1.2.3")
        XCTAssertNil(req.httpBody)
    }

    // MARK: Redirect / host 信任(縱深防禦契約)

    func testRedirectAlwaysRefusedAndTrustedResponseHost() {
        XCTAssertNil(OpenRouterCreditsEngine.redirectDecision(), "redirect 一律拒絕")
        XCTAssertTrue(OpenRouterCreditsEngine.isTrustedResponse(url: URL(string: "https://openrouter.ai/api/v1/credits")))
        XCTAssertFalse(OpenRouterCreditsEngine.isTrustedResponse(url: URL(string: "http://openrouter.ai/api/v1/credits")), "非 https 不信任")
        XCTAssertFalse(OpenRouterCreditsEngine.isTrustedResponse(url: URL(string: "https://api.openrouter.ai/x")), "子網域不信任")
        XCTAssertFalse(OpenRouterCreditsEngine.isTrustedResponse(url: URL(string: "https://evil.example/api/v1/credits")))
        XCTAssertFalse(OpenRouterCreditsEngine.isTrustedResponse(url: nil))
    }

    // MARK: 回應解析(2xx 窄解碼;缺欄位絕不補 0)

    func testParseResponseHappyPath() {
        let body = Data(#"{"data":{"total_credits":40,"total_usage":10.4302712}}"#.utf8)
        let now = Date()
        guard case let .success(snap) = OpenRouterCreditsEngine.parseResponse(statusCode: 200, data: body, now: now) else {
            XCTAssertTrue(false, "expected success"); return
        }
        XCTAssertEqual(snap.totalCredits, 40, accuracy: 0.0001)
        XCTAssertEqual(snap.totalUsage, 10.4302712, accuracy: 0.0000001)
        XCTAssertEqual(snap.remaining, 29.5697288, accuracy: 0.0000001)
        XCTAssertEqual(snap.fetchedAt, now)
    }

    func testParseResponseNarrowAndFailClosed() {
        // 額外欄位照樣成功(窄解碼,不解其他欄位)
        let extra = Data(#"{"data":{"total_credits":5,"total_usage":1,"is_free_tier":false,"extra":{"x":1}}}"#.utf8)
        if case .success = OpenRouterCreditsEngine.parseResponse(statusCode: 200, data: extra, now: Date()) {} else {
            XCTAssertTrue(false, "narrow decode should tolerate extra fields")
        }
        // 缺欄位 → badReply(missing ≠ 0)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(
            statusCode: 200, data: Data(#"{"data":{"total_credits":40}}"#.utf8), now: Date()), .badReply)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(
            statusCode: 200, data: Data(#"{"data":{}}"#.utf8), now: Date()), .badReply)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(
            statusCode: 200, data: Data(#"{}"#.utf8), now: Date()), .badReply)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(
            statusCode: 200, data: Data("html!".utf8), now: Date()), .badReply)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(
            statusCode: 204, data: Data(), now: Date()), .badReply)
        // 回應超限 → badReply
        let huge = Data(repeating: 0x20, count: OpenRouterCreditsEngine.maxResponseBytes + 1)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(statusCode: 200, data: huge, now: Date()), .badReply)
        // 401/403 → keyRejected;其他非 2xx → serverError
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(statusCode: 401, data: Data(), now: Date()), .keyRejected)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(statusCode: 403, data: Data(), now: Date()), .keyRejected)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(statusCode: 500, data: Data(), now: Date()), .serverError)
        XCTAssertEqual(OpenRouterCreditsEngine.parseResponse(statusCode: 302, data: Data(), now: Date()), .serverError)
    }

    // MARK: 快照語意(signed remaining;clamp 只在 bar 幾何)

    func testSnapshotRemainingIsSignedAndFractionClampsGeometryOnly() {
        let over = OpenRouterCreditsSnapshot(totalCredits: 10, totalUsage: 10.12, fetchedAt: Date())
        XCTAssertEqual(over.remaining, -0.12, accuracy: 0.0001, "透支如實為負,不 max(0,·) 假裝歸零")
        XCTAssertEqual(over.remainingFraction ?? -1, 0, accuracy: 0.0001, "bar 幾何 clamp 到 0")
        let zero = OpenRouterCreditsSnapshot(totalCredits: 0, totalUsage: 0, fetchedAt: Date())
        XCTAssertNil(zero.remainingFraction, "totalCredits ≤ 0 → 無 bar(missing ≠ 0)")
        let negativeCredits = OpenRouterCreditsSnapshot(totalCredits: -5, totalUsage: 0, fetchedAt: Date())
        XCTAssertNil(negativeCredits.remainingFraction)
    }

    func testMoneyAndAgeFormatting() {
        XCTAssertEqual(OpenRouterCreditsStatus.fmtUSD(29.5697), "$29.57")
        XCTAssertEqual(OpenRouterCreditsStatus.fmtUSD(-0.1234), "-$0.12")
        XCTAssertEqual(OpenRouterCreditsStatus.fmtUSD(0), "$0.00")
        XCTAssertEqual(OpenRouterCreditsStatus.fmtUSD(1234.5), "$1234.50")
        XCTAssertEqual(OpenRouterCreditsStatus.compactAge(seconds: 30), "now")
        XCTAssertEqual(OpenRouterCreditsStatus.compactAge(seconds: 185), "3m")
        XCTAssertEqual(OpenRouterCreditsStatus.compactAge(seconds: 7200), "2h")
        XCTAssertEqual(OpenRouterCreditsStatus.compactAge(seconds: 200_000), "2d")
    }

    // MARK: 呈現(封閉詞彙;所有表面共用)

    private func snap(_ credits: Double, _ usage: Double, ageMinutes: Double, now: Date) -> OpenRouterCreditsSnapshot {
        OpenRouterCreditsSnapshot(totalCredits: credits, totalUsage: usage,
                                  fetchedAt: now.addingTimeInterval(-ageMinutes * 60))
    }

    func testPresentationFreshSuccess() {
        let now = Date()
        let s = snap(40, 10.4302712, ageMinutes: 3, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: s.fetchedAt, lastOutcome: .success(s))
        let p = status.presentation(now: now)
        XCTAssertEqual(p.primary, "$29.57 left")
        XCTAssertEqual(p.detail, "of $40.00")
        XCTAssertEqual(p.age, "3m")
        XCTAssertFalse(p.stale)
        XCTAssertEqual(p.barFraction ?? -1, 29.5697288 / 40, accuracy: 0.0001)
        XCTAssertEqual(p.bubbleUsageLine, "OR $29.57 left")
        XCTAssertEqual(p.bubbleDataLine, "OR reported · 3m")
        // computed 值不冠「official」;tooltip 為歸因句(reported totals + recency)
        XCTAssertFalse(p.tooltip.contains("official"))
        XCTAssertTrue(p.tooltip.contains("OpenRouter-reported totals"))
        XCTAssertTrue(p.tooltip.contains("$40.00 purchased"))
        XCTAssertTrue(p.tooltip.contains("3m ago"))
    }

    func testPresentationStaleByAge() {
        let now = Date()
        let s = snap(40, 10, ageMinutes: 45, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: s.fetchedAt, lastOutcome: .success(s))
        let p = status.presentation(now: now)
        XCTAssertTrue(p.stale, "快照超過 30 分鐘 → stale")
        XCTAssertEqual(p.primary, "$30.00 left")
        XCTAssertEqual(p.bubbleUsageLine, "OR $30.00 left · 45m", "stale 時泡泡行必附年齡")
    }

    func testPresentationFailedAttemptKeepsAgedValueHonestly() {
        let now = Date()
        let s = snap(40, 10.43, ageMinutes: 120, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: now, lastOutcome: .networkError)
        let p = status.presentation(now: now)
        XCTAssertEqual(p.primary, "can't reach OpenRouter")
        XCTAssertEqual(p.detail, "last $29.57 · 2h")
        XCTAssertTrue(p.stale)
        XCTAssertNil(p.barFraction, "刷新失敗 → 不畫 bar,避免看似即時")
        XCTAssertNil(p.bubbleUsageLine, "用量頁整行省略,不顯示可能過期的值")
        XCTAssertEqual(p.bubbleDataLine, "OR unreachable · 2h")
    }

    func testPresentationErrorStatesWithoutSnapshot() {
        let now = Date()
        func present(_ outcome: OpenRouterCreditsOutcome?) -> OpenRouterCreditsStatus.Presentation {
            OpenRouterCreditsStatus(snapshot: nil, lastAttemptAt: outcome == nil ? nil : now,
                                    lastOutcome: outcome).presentation(now: now)
        }
        XCTAssertEqual(present(nil).primary, "checking…")
        XCTAssertNil(present(nil).bubbleDataLine)
        XCTAssertEqual(present(.noKey).primary, "no key — log in with opencode")
        XCTAssertEqual(present(.noKey).bubbleDataLine, "OR no key")
        XCTAssertEqual(present(.keyRejected).primary, "key rejected — re-log in with opencode")
        XCTAssertEqual(present(.networkError).primary, "can't reach OpenRouter")
        XCTAssertEqual(present(.serverError).primary, "can't reach OpenRouter")
        XCTAssertEqual(present(.badReply).primary, "unexpected reply from OpenRouter")
        for outcome in [OpenRouterCreditsOutcome.noKey, .keyRejected, .networkError, .serverError, .badReply] {
            let p = present(outcome)
            XCTAssertNil(p.bubbleUsageLine, "無快照的錯誤態不得出現在用量頁")
            XCTAssertNil(p.barFraction)
            XCTAssertFalse(p.tooltip.contains("sk-"), "任何呈現字串不得含 key 樣式")
        }
    }

    func testPresentationZeroCreditsNeverRendersZeroOfZero() {
        let now = Date()
        let s = snap(0, 0, ageMinutes: 0, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: now, lastOutcome: .success(s))
        let p = status.presentation(now: now)
        XCTAssertEqual(p.primary, "no prepaid credits")
        XCTAssertNil(p.detail, "絕不渲染「$0.00 left of $0」")
        XCTAssertNil(p.barFraction)
        // 成功取得的零額度是資料,不是錯誤 → 用量頁照樣呈現(R2 codex F4)。
        XCTAssertEqual(p.bubbleUsageLine, "OR no credits")
        XCTAssertEqual(p.bubbleDataLine, "OR no credits · now")
    }

    func testPresentationFailedAfterZeroCreditsShowsFailureNotZeroClaim() {
        // R2 codex F4:零額度快照 + 之後刷新失敗 → 失敗分支優先,不得繼續宣稱
        // 「no prepaid credits」而藏住失敗。
        let now = Date()
        let s = snap(0, 0, ageMinutes: 90, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: now, lastOutcome: .networkError)
        let p = status.presentation(now: now)
        XCTAssertEqual(p.primary, "can't reach OpenRouter")
        XCTAssertEqual(p.detail, "no prepaid credits · 1h")
        XCTAssertTrue(p.stale)
        XCTAssertNil(p.bubbleUsageLine)
        XCTAssertEqual(p.bubbleDataLine, "OR unreachable · 1h")
        XCTAssertFalse(p.tooltip.contains("$0.00"), "失敗 tooltip 不得渲染 $0 假值")
    }

    func testPresentationStaleBoundaryAt30Minutes() {
        let now = Date()
        func stale(afterSeconds: Double) -> Bool {
            let s = OpenRouterCreditsSnapshot(totalCredits: 40, totalUsage: 10,
                                              fetchedAt: now.addingTimeInterval(-afterSeconds))
            return OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: s.fetchedAt,
                                           lastOutcome: .success(s)).presentation(now: now).stale
        }
        XCTAssertFalse(stale(afterSeconds: 30 * 60 - 1), "29m59s 尚未 stale")
        XCTAssertTrue(stale(afterSeconds: 30 * 60 + 1), "30m01s 已 stale")
    }

    // MARK: 抓取生命週期閘(R2 grok F1/F2、codex F1 的回歸鎖)

    func testFetchGateSingleFlightAndGenerationSemantics() {
        var gate = OpenRouterFetchGate()
        // 單流:佔用中不得再開始
        let t1 = gate.tryBegin()
        XCTAssertNotNil(t1)
        XCTAssertNil(gate.tryBegin(), "in-flight 時第二個 fetch 必須被擋")
        // 正常結束釋放
        gate.end(t1!)
        XCTAssertNil(gate.activeGeneration)
        // bump 強制釋放:停用→啟用不必等舊 fetch 退場
        let t2 = gate.tryBegin()!
        gate.bumpGeneration()
        XCTAssertNil(gate.activeGeneration, "bump 必須強制釋放單流佔用")
        XCTAssertFalse(gate.shouldCommit(t2), "舊 token 的結果必須被丟棄")
        // 新 fetch 開始後,舊 fetch 的 end 不得誤清新佔用
        let t3 = gate.tryBegin()!
        gate.end(t2)
        XCTAssertNotNil(gate.activeGeneration, "舊 end 不得清掉新 fetch 的佔用")
        XCTAssertTrue(gate.shouldCommit(t3))
        gate.end(t3)
        XCTAssertNil(gate.activeGeneration)
    }

    func testPresentationOverspendShowsHonestNegative() {
        let now = Date()
        let s = snap(10, 10.12, ageMinutes: 1, now: now)
        let status = OpenRouterCreditsStatus(snapshot: s, lastAttemptAt: now, lastOutcome: .success(s))
        let p = status.presentation(now: now)
        XCTAssertEqual(p.primary, "over by $0.12", "透支如實顯示,不假裝 $0.00 left")
        XCTAssertEqual(p.barFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(p.bubbleUsageLine, "OR over by $0.12")
    }

    // MARK: 泡泡行預算(決定性 +N more,絕不靜默截斷)

    func testBubbleComposeWithoutExtraIsIdentityUpToBudget() {
        for n in 0...4 {
            let lines = (0..<n).map { "P\($0)" }
            XCTAssertEqual(BubblePages.compose(providerLines: lines, extraLine: nil), lines,
                           "extra 為 nil 且 ≤4 行時輸出位元不變")
        }
        let five = ["A", "B", "C", "D", "E"]
        XCTAssertEqual(BubblePages.compose(providerLines: five, extraLine: nil),
                       ["A", "B", "C", "+2 more"])
    }

    func testBubbleComposeWithExtraLine() {
        XCTAssertEqual(BubblePages.compose(providerLines: [], extraLine: "OR $5.00 left"),
                       ["OR $5.00 left"])
        XCTAssertEqual(BubblePages.compose(providerLines: ["A", "B", "C"], extraLine: "OR"),
                       ["A", "B", "C", "OR"], "3 家 + OR 恰好 4 行")
        XCTAssertEqual(BubblePages.compose(providerLines: ["A", "B", "C", "D"], extraLine: "OR"),
                       ["A", "B", "+2 more", "OR"], "第 4 家收進 +N more,使用者看得見有收合")
        XCTAssertEqual(BubblePages.compose(providerLines: ["A", "B", "C", "D", "E"], extraLine: "OR"),
                       ["A", "B", "+3 more", "OR"], "5 家 + extra 仍收斂在 4 行")
    }

    func testBubbleComposeDataPageBudget() {
        // 資料頁:refreshed 行在外部,flags 預算 3(含 OR)
        XCTAssertEqual(BubblePages.compose(providerLines: ["CC official", "CX official"],
                                           extraLine: "OR reported · 3m", maxLines: 3),
                       ["CC official", "CX official", "OR reported · 3m"])
        XCTAssertEqual(BubblePages.compose(providerLines: ["CC x", "CX y", "GK z", "AG w"],
                                           extraLine: "OR reported · 3m", maxLines: 3),
                       ["CC x", "+3 more", "OR reported · 3m"])
    }
}
