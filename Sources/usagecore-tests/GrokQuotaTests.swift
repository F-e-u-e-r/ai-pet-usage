import Foundation
import UsageCore

// F3 Grok 額度純邏輯層測試(契約 v5 §2 credits / §4 Grok 列 / §5 fixtures 表)。

final class GrokQuotaTests: XCTestCase {
    let now = date("2026-08-09T10:00:00Z")

    private func body(_ json: String) -> Data { json.data(using: .utf8)! }

    // MARK: decoder(versioned;契約 §5)

    func testParseSuccessNestedAndAdditiveTolerance() {
        // 實抓 shape(config 巢狀)+ 未知欄位(additive)必須容忍
        let json = """
        {"config": {"creditUsagePercent": 41.5,
                    "currentPeriod": {"start": "2026-08-01T00:00:00Z", "end": "2026-09-01T00:00:00Z"},
                    "plan": "pro", "someFutureField": {"x": 1}},
         "anotherUnknownTopLevel": true}
        """
        guard case .success(let snap) = GrokQuotaEngine.parseResponse(statusCode: 200, data: body(json), now: now) else {
            return XCTAssertTrue(false, "additive 欄位不得阻擋成功解碼")
        }
        XCTAssertEqual(snap.usedPercent, 41.5, accuracy: 0.001)
        XCTAssertEqual(snap.periodEnd, date("2026-09-01T00:00:00Z"), "periodEnd = 重置時間")
        XCTAssertEqual(snap.planName, "pro")
        XCTAssertEqual(snap.fetchedAt, now)
    }

    func testParseBreakingWhenRequiredFieldMissingOrWrongType() {
        // 必要欄位 creditUsagePercent:缺 → breaking(立即 kill 級;契約 §5)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"config": {"plan": "pro"}}"#), now: now), .schemaBreaking)
        // 型別錯(字串)→ breaking
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"config": {"creditUsagePercent": "41%"}}"#), now: now), .schemaBreaking)
        // 非有限/負值 → breaking(不得顯示假數)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"config": {"creditUsagePercent": -3}}"#), now: now), .schemaBreaking)
    }

    func testBoolAndNonObjectRootAreSchemaBreaking() {
        // r1 三鏡:JSON true 經 NSNumber 橋接不得變 1%
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"config": {"creditUsagePercent": true}}"#), now: now), .schemaBreaking)
        // r1 ultra:合法 JSON 但非物件(陣列 root)= 結構型別錯 → breaking(非 invalidBody)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body("[1, 2, 3]"), now: now), .schemaBreaking)
        // scalar fragment("42"):JSONSerialization 預設(無 .fragmentsAllowed)視為
        // 非法文件 → invalidBody(×3 通道);刻意不放寬解析面。
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body("42"), now: now), .invalidBody)
    }

    func testParseInvalidBodyAndHTTPMapping() {
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body("not json"), now: now), .invalidBody)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 401, data: Data(), now: now), .keyRejected)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 429, data: Data(), now: now),
                       .rateLimited(retryAfterSeconds: nil))
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 500, data: Data(), now: now), .serverError)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 404, data: Data(), now: now), .endpointGone)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 410, data: Data(), now: now), .endpointGone)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 403, data: Data(), now: now), .badReply,
                       "403 語義曖昧 → transientError 類,不誘導重登(契約 §5)")
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 400, data: Data(), now: now), .badReply)
        // 超限回應 → badReply(縱深;下載期另有硬斷)
        let oversized = Data(repeating: 0x20, count: GrokQuotaEngine.maxResponseBytes + 1)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: oversized, now: now), .badReply)
        // percent > 100 → clamp(顯示恆 ≤100)
        guard case .success(let snap) = GrokQuotaEngine.parseResponse(statusCode: 200,
              data: body(#"{"config": {"creditUsagePercent": 240}}"#), now: now) else {
            return XCTAssertTrue(false)
        }
        XCTAssertEqual(snap.usedPercent, 100)
    }

    func testEpochPeriodTimestampsTolerated() {
        // 週期為 epoch 秒或毫秒數值也容忍(additive-tolerant)
        let json = #"{"config": {"creditUsagePercent": 10, "currentPeriod": {"start": 1754006400, "end": 1756684800000}}}"#
        guard case .success(let snap) = GrokQuotaEngine.parseResponse(statusCode: 200, data: body(json), now: now) else {
            return XCTAssertTrue(false)
        }
        XCTAssertEqual(snap.periodStart, Date(timeIntervalSince1970: 1_754_006_400))
        XCTAssertEqual(snap.periodEnd, Date(timeIntervalSince1970: 1_756_684_800), "毫秒值需 /1000")
    }

    // MARK: 事件映射 + 狀態機整合(F17 substrate 消費)

    func testObservationEventMappingAndMachineIntegration() {
        XCTAssertEqual(GrokQuotaOutcome.keyRejected.observationEvent, .authRejected)
        XCTAssertEqual(GrokQuotaOutcome.schemaBreaking.observationEvent, .schemaBreaking)
        XCTAssertEqual(GrokQuotaOutcome.invalidBody.observationEvent, .invalidBody)
        XCTAssertEqual(GrokQuotaOutcome.endpointGone.observationEvent, .endpointGone)
        XCTAssertEqual(GrokQuotaOutcome.serverError.observationEvent, .transportFailure)
        XCTAssertEqual(GrokQuotaOutcome.rateLimited(retryAfterSeconds: 30).observationEvent, .rateLimited)
        // 端到端:breaking 一發 kill;invalidBody 三發 kill;5xx 永不 kill
        var s = SourceHealthMachine.State()
        s = SourceHealthMachine.step(s, GrokQuotaOutcome.schemaBreaking.observationEvent)
        XCTAssertEqual(s.health, .schemaKilled)
        var t = SourceHealthMachine.State()
        for _ in 0..<3 { t = SourceHealthMachine.step(t, GrokQuotaOutcome.invalidBody.observationEvent) }
        XCTAssertEqual(t.health, .schemaKilled)
        var u = SourceHealthMachine.State()
        for _ in 0..<5 { u = SourceHealthMachine.step(u, GrokQuotaOutcome.serverError.observationEvent) }
        XCTAssertEqual(u.health, .transientError)
    }

    // MARK: request 構造(boundary #73)

    func testRequestShapeAndRedirectRefusal() {
        let r = GrokQuotaEngine.request(key: "tok-abc", appVersion: "0.1.6")
        XCTAssertEqual(r.url?.host, "cli-chat-proxy.grok.com", "唯一 host")
        XCTAssertEqual(r.url?.scheme, "https")
        XCTAssertTrue(r.url?.query?.contains("format=credits") == true)
        // token-safe 斷言(r1 ultra/sol:失敗輸出不得帶 Bearer/token 字串 —— 結構性檢查)
        let auth = r.value(forHTTPHeaderField: "Authorization")
        XCTAssertTrue(auth?.hasPrefix("Bearer ") == true, "Authorization 應為 Bearer 型式")
        XCTAssertEqual(auth?.count, "Bearer ".count + "tok-abc".count, "header 僅含前綴+token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
        XCTAssertNil(r.httpBody, "GET 無 body:零用量資料上行")
        XCTAssertNil(GrokQuotaEngine.redirectDecision(), "redirect 一律拒絕")
        XCTAssertFalse(GrokQuotaEngine.isTrustedResponse(url: URL(string: "https://evil.example/v1")),
                       "非唯一 host 的回應不可信")
        XCTAssertFalse(GrokQuotaEngine.isTrustedResponse(url: URL(string: "http://cli-chat-proxy.grok.com/x")),
                       "非 https 不可信")
    }

    // MARK: key narrow 解碼(契約 §4 生命週期表)

    func testKeyParserNarrowAndCaps() {
        let parsed = GrokKeyParser.parse(data: body(#"{"key": "tok-1", "refresh": "SECRET-NEVER-READ"}"#))
        XCTAssertTrue(parsed == "tok-1", "只解 key 欄(布林斷言:失敗輸出不印 key 值)")
        XCTAssertTrue(parsed?.contains("SECRET") != true, "refresh 欄位永不 materialize")
        XCTAssertNil(GrokKeyParser.parse(data: body(#"{"refresh": "x"}"#)), "key 缺 → nil(→ notLoggedIn 語義)")
        XCTAssertNil(GrokKeyParser.parse(data: body(#"{"key": ""}"#)), "空 key → nil")
        XCTAssertNil(GrokKeyParser.parse(data: body("not json")), "壞 JSON → nil(transientError 語義,絕不顯重登)")
        let oversized = Data(repeating: 0x20, count: GrokKeyParser.maxAuthFileBytes + 1)
        XCTAssertNil(GrokKeyParser.parse(data: oversized), ">1MB 拒讀")
    }

    // MARK: Policy 決策核心(owner 六 lifecycle case 的純邏輯面)

    func testPolicyZeroEgressWhenDisabledAndFull401Cycle() {
        typealias G = CredentialChangeGate
        let statA = G.FileStat(mtime: date("2026-08-09T09:00:00Z"), size: 120, exists: true)
        let statB = G.FileStat(mtime: date("2026-08-09T09:30:00Z"), size: 120, exists: true)
        var p = GrokQuotaPolicy()
        // case 1:toggle off → 零 egress(手動也不例外)
        XCTAssertEqual(p.decision(enabled: false, currentStat: statA, isManual: false), .skipDisabled)
        XCTAssertEqual(p.decision(enabled: false, currentStat: statA, isManual: true), .skipDisabled,
                       "off 下手動 refresh 也零 egress")
        // case 4:401 全循環
        XCTAssertEqual(p.decision(enabled: true, currentStat: statA, isManual: false), .proceed)
        p.apply(outcome: .keyRejected, statAtFetch: statA)
        XCTAssertEqual(p.machine.health, .authExpired)
        XCTAssertEqual(p.decision(enabled: true, currentStat: statA, isManual: false), .skipCredentialUnchanged)
        XCTAssertEqual(p.decision(enabled: true, currentStat: statA, isManual: false), .skipCredentialUnchanged,
                       "純時間流逝不解鎖(任意多 tick)")
        XCTAssertEqual(p.decision(enabled: true, currentStat: statA, isManual: true), .proceed,
                       "manual refresh 解鎖(第二門檻)")
        XCTAssertEqual(p.decision(enabled: true, currentStat: statB, isManual: false), .proceed,
                       "mtime 變化解鎖")
        // 下一次仍 401 → 立即以新身分重新 blocked
        p.apply(outcome: .keyRejected, statAtFetch: statB)
        XCTAssertEqual(p.decision(enabled: true, currentStat: statB, isManual: false), .skipCredentialUnchanged)
        // 成功 → 門檻解除 + machine 回 ok
        p.apply(outcome: .success(GrokQuotaSnapshot(usedPercent: 10, periodStart: nil, periodEnd: nil,
                                                    planName: nil, fetchedAt: now)), statAtFetch: statB)
        XCTAssertEqual(p.machine.health, .ok)
        XCTAssertEqual(p.decision(enabled: true, currentStat: statB, isManual: false), .proceed)
        // 非 401 失敗不動門檻(5xx 後照常嘗試)
        p.apply(outcome: .serverError, statAtFetch: statB)
        XCTAssertEqual(p.machine.health, .transientError)
        XCTAssertEqual(p.decision(enabled: true, currentStat: statB, isManual: false), .proceed)
    }

    func testPolicyOverflowAnomalyIsNotSilent() {
        guard case .success(let snap) = GrokQuotaEngine.parseResponse(statusCode: 200,
              data: body(#"{"config": {"creditUsagePercent": 240}}"#), now: now) else {
            return XCTAssertTrue(false)
        }
        XCTAssertEqual(snap.usedPercent, 100, "顯示 clamp")
        XCTAssertTrue(snap.reportedPercentOverflow, "raw >100 必須留 anomaly 標記(不靜默;owner 裁示)")
        guard case .success(let normal) = GrokQuotaEngine.parseResponse(statusCode: 200,
              data: body(#"{"config": {"creditUsagePercent": 42}}"#), now: now) else {
            return XCTAssertTrue(false)
        }
        XCTAssertFalse(normal.reportedPercentOverflow)
    }

    // MARK: 401 重試門檻(契約 §4:檔變更或手動,無時間例外)

    func testCredentialChangeGate() {
        typealias G = CredentialChangeGate
        let statA = G.FileStat(mtime: date("2026-08-09T09:00:00Z"), size: 120, exists: true)
        var gate = G()
        XCTAssertTrue(gate.shouldAttempt(currentStat: statA), "無 401 在案 → 照常外呼")
        gate.noteRejected(stat: statA)
        XCTAssertFalse(gate.shouldAttempt(currentStat: statA), "檔未變 → 永久 skip(零外呼)")
        XCTAssertFalse(gate.shouldAttempt(currentStat: statA), "任意多 tick 後仍 skip(無時間例外)")
        let mtimeChanged = G.FileStat(mtime: date("2026-08-09T09:30:00Z"), size: 120, exists: true)
        XCTAssertTrue(gate.shouldAttempt(currentStat: mtimeChanged), "mtime 變(重登/輪替)→ 立即重試")
        let sizeChanged = G.FileStat(mtime: statA.mtime, size: 121, exists: true)
        XCTAssertTrue(gate.shouldAttempt(currentStat: sizeChanged), "size-only 變更也觸發(契約 fixture)")
        let fileGone = G.FileStat(mtime: nil, size: nil, exists: false)
        XCTAssertTrue(gate.shouldAttempt(currentStat: fileGone),
                      "檔案消失 = 身分變更(呼叫端會轉 notLoggedIn,不會真外呼)")
        gate.clear()
        XCTAssertTrue(gate.shouldAttempt(currentStat: statA), "成功後門檻解除")
    }
}
