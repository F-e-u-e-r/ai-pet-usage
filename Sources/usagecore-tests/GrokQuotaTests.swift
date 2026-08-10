import Foundation
import UsageCore

// F3 Grok 額度純邏輯層測試(契約 v5 §2 credits / §4 Grok 列 / §5 fixtures 表)。

final class GrokQuotaTests: XCTestCase {
    let now = date("2026-08-09T10:00:00Z")

    private func body(_ json: String) -> Data { json.data(using: .utf8)! }

    // MARK: decoder(F3 hotfix 分類;Track A:creditUsagePercent 已撤除為 weekly-quota source)

    func testValidEnvelopeNeverRendersCreditUsagePercentAsQuota() {
        // Track A 核心 + owner 要求的 regression:creditUsagePercent(Track B 已證 ≠ Grok weekly quota)
        // 無論何值/在否,一律 → .noUsageData(honestly unavailable),**絕不** render 成 Grok quota N%。
        for pct in ["100.0", "41.5", "0", "1", "true", "\"41%\"", "-3", "null"] {
            XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                data: body("{\"config\": {\"creditUsagePercent\": \(pct)}}"), now: now), .noUsageData,
                "creditUsagePercent=\(pct)(有效 config envelope)→ .noUsageData,不得 render 為 quota")
        }
        // 缺 creditUsagePercent 的真實 200(currentPeriod/billing 欄在)→ 一樣 .noUsageData(非 kill)
        let realAbsent = #"{"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-08-06T13:58:47.849415+00:00", "end": "2026-08-13T13:58:47.849415+00:00"}, "onDemandCap": {"val": 0}, "prepaidBalance": {"val": 0}, "billingPeriodEnd": "2026-08-13T13:58:47.849415+00:00"}}"#
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body(realAbsent), now: now), .noUsageData)
        // additive:未知頂層/巢狀欄位不改變分類
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
            data: body(#"{"config": {"creditUsagePercent": 42, "future": {"x": 1}}, "unknownTop": true}"#), now: now),
            .noUsageData)
    }

    func testEnvelopeClassification() {
        // 無 config(error / 無法辨識)→ .badReply(transient:不標健康、不清 401 門檻、不 kill)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"error": {"code": "unauthorized"}}"#), now: now), .badReply, "error-envelope → transient")
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"someOtherEnvelope": true}"#), now: now), .badReply, "無 config → transient")
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body("{}"), now: now), .badReply, "空物件 → transient")
        // 明確 error key,即使 config 在 → 仍 .badReply(r3 luna/sol:不因 config 在而軟當 success)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200,
                       data: body(#"{"error": {"code": "x"}, "config": {"creditUsagePercent": 50}}"#), now: now),
                       .badReply, "error key(即使 config 在)→ transient")
        // root 非物件(陣列)= evidence-backed 結構破壞 → schemaBreaking(唯一保留的 kill)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body("[1, 2, 3]"), now: now),
                       .schemaBreaking, "root 非物件 → 結構破壞 → kill")
        // scalar fragment / 壞 JSON → invalidBody(×3 通道)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body("42"), now: now), .invalidBody)
        XCTAssertEqual(GrokQuotaEngine.parseResponse(statusCode: 200, data: body("not json"), now: now), .invalidBody)
    }

    func testHTTPStatusAndOversizedMapping() {
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
    }

    // MARK: 事件映射 + 狀態機整合(F17 substrate 消費)

    func testObservationEventMappingAndMachineIntegration() {
        XCTAssertEqual(GrokQuotaOutcome.keyRejected.observationEvent, .authRejected)
        XCTAssertEqual(GrokQuotaOutcome.schemaBreaking.observationEvent, .schemaBreaking)
        XCTAssertEqual(GrokQuotaOutcome.invalidBody.observationEvent, .invalidBody)
        XCTAssertEqual(GrokQuotaOutcome.endpointGone.observationEvent, .endpointGone)
        XCTAssertEqual(GrokQuotaOutcome.serverError.observationEvent, .transportFailure)
        XCTAssertEqual(GrokQuotaOutcome.rateLimited(retryAfterSeconds: 30).observationEvent, .rateLimited)
        XCTAssertEqual(GrokQuotaOutcome.noUsageData.observationEvent, .success, "有效 200 無 % = 源健康,非故障")
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
        // noUsageData 永不 kill:任意多次(有效 200 只是資料暫缺)→ 源保持 ok
        var n = SourceHealthMachine.State()
        for _ in 0..<5 { n = SourceHealthMachine.step(n, GrokQuotaOutcome.noUsageData.observationEvent) }
        XCTAssertEqual(n.health, .ok, "noUsageData 永不升級 schemaKilled;源保持 ok")
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

    // MARK: key narrow 解碼(真實巢狀 shape + deterministic selector;live-validated 2026-08-09)

    /// 合成一個帳號 entry:`"<issuer>": {"key": …, "expires_at": …, "user_id": "u"}`(值皆合成,無真實憑證/PII)。
    private func account(_ issuer: String, key: String, expires: String? = nil) -> String {
        let exp = expires.map { #""expires_at": "\#($0)", "# } ?? ""
        return #""\#(issuer)": {"key": "\#(key)", \#(exp)"user_id": "u"}"#
    }

    func testKeyParserNestedRealSchemaAndNarrow() {
        // 真實 shape(單帳號):token 巢狀;refresh_token/email/PII 為同層 sibling —— 絕不進結果。
        let json = #"""
        {"https://auth.x.ai::abc-123": {
            "key": "tok-REAL", "auth_mode": "oidc", "email": "a@b.c", "first_name": "A",
            "refresh_token": "SECRET-NEVER-READ", "team_id": "t",
            "expires_at": "2026-12-01T00:00:00.500000+00:00", "oidc_issuer": "https://auth.x.ai"}}
        """#
        guard case .key(let k) = GrokKeyParser.parse(data: body(json), now: now) else {
            return XCTAssertTrue(false, "真實巢狀 shape 必須解出 key")
        }
        // k == 選出的巢狀 `key`,而非 refresh_token 的值("SECRET-NEVER-READ")→ 證明選的是 key 欄
        // 而非誤取 sibling;narrow-decode(siblings 永不 materialize)的實證在下一個 adversarial 測試。
        XCTAssertEqual(k, "tok-REAL", "選出的是巢狀 key,不是 refresh_token/其他欄的值")
    }

    func testKeyParserNarrowIgnoresAdversarialSiblingTypes() {
        // 惡意 sibling 型別:refresh_token 是物件、email 是陣列、team_id 是數字、expires_at 型別怪。
        // 寬 decoder 會在這些型別上爆掉;narrow decoder 只讀 key/expires_at,必須仍成功解出 key。
        let json = #"""
        {"https://auth.x.ai::x": {
            "key": "tok-OK",
            "refresh_token": {"nested": ["object", "not", "string"]},
            "email": ["array", "of", "things"],
            "coding_data_retention_opt_out": true,
            "team_id": 12345,
            "expires_at": {"weird": "type"}}}
        """#
        guard case .key(let k) = GrokKeyParser.parse(data: body(json), now: now) else {
            return XCTAssertTrue(false, "narrow decode 必須無視惡意 sibling 型別而成功")
        }
        XCTAssertEqual(k, "tok-OK", "只讀 key;expires_at 型別怪 → 視為未知,不影響解出 key")
    }

    func testKeyParserMultiAccountDeterministicSelection() {
        let future1 = "2027-01-01T00:00:00Z"
        let future2 = "2027-06-01T00:00:00Z"   // 更晚
        let past = "2020-01-01T00:00:00Z"
        func pick(_ entries: String...) -> String? {
            guard case .key(let k) = GrokKeyParser.parse(
                data: body("{" + entries.joined(separator: ",") + "}"), now: now) else { return nil }
            return k
        }
        // (a) 未過期優先於過期(無視 account 字典序)
        XCTAssertEqual(pick(account("https://auth.x.ai::a-expired", key: "EXP", expires: past),
                            account("https://auth.x.ai::z-valid", key: "VALID", expires: future1)), "VALID")
        // (b) 同為未過期:x.ai issuer 優先(即使對方 expiry 更晚)
        XCTAssertEqual(pick(account("https://auth.other.com::a", key: "OTHER", expires: future2),
                            account("https://auth.x.ai::z", key: "XAI", expires: future1)), "XAI")
        // (c) 同 band 同 issuer:晚 expiry 優先
        XCTAssertEqual(pick(account("https://auth.x.ai::a", key: "EARLY", expires: future1),
                            account("https://auth.x.ai::b", key: "LATE", expires: future2)), "LATE")
        // (d) 完全同 rank:account 字典序作最後決定性 tie-break(殺 dict 迭代非決定性)
        XCTAssertEqual(pick(account("https://auth.x.ai::zzz", key: "Z", expires: future1),
                            account("https://auth.x.ai::aaa", key: "A", expires: future1)), "A")
        // (e) 缺 expires_at = 未知 band(介於未過期與過期);不因缺 expiry 判過期
        XCTAssertEqual(pick(account("https://auth.x.ai::a-unknown", key: "UNKNOWN"),
                            account("https://auth.x.ai::b-expired", key: "EXPIRED", expires: past)), "UNKNOWN")
    }

    func testKeyParserFormatUnrecognizedVsRetryable() {
        // retryable(transient):非 JSON / 非物件 / 超限
        XCTAssertEqual(GrokKeyParser.parse(data: body("not json"), now: now), .malformed)
        XCTAssertEqual(GrokKeyParser.parse(data: body("[1,2,3]"), now: now), .malformed, "陣列非帳號字典")
        XCTAssertEqual(GrokKeyParser.parse(data: body("42"), now: now), .malformed)
        // 有效但超限的 store:證明是 1MB CAP(而非「非 JSON」)在拒讀 —— 若移除 cap,這會解成 .key。
        let hugeKey = String(repeating: "A", count: GrokKeyParser.maxAuthFileBytes)
        let oversizedValid = body(#"{"https://auth.x.ai::a": {"key": "\#(hugeKey)"}}"#)
        XCTAssertGreaterThan(oversizedValid.count, GrokKeyParser.maxAuthFileBytes, "fixture 必須真的超過 cap")
        XCTAssertEqual(GrokKeyParser.parse(data: oversizedValid, now: now), .malformed, ">1MB 有效 store 仍被 cap 拒讀")
        // formatUnrecognized:合法物件但無可用 key(非 transient —— 不無限重試同一 bytes)
        XCTAssertEqual(GrokKeyParser.parse(data: body("{}"), now: now), .formatUnrecognized, "空 {} → 格式不符")
        XCTAssertEqual(GrokKeyParser.parse(data: body(#"{"acct": {"refresh_token": "x"}}"#), now: now),
                       .formatUnrecognized, "entry 無 key → 格式不符")
        XCTAssertEqual(GrokKeyParser.parse(data: body(#"{"acct": {"key": ""}}"#), now: now),
                       .formatUnrecognized, "空 key → 格式不符")
        XCTAssertEqual(GrokKeyParser.parse(data: body(#"{"acct": {"key": 123}}"#), now: now),
                       .formatUnrecognized, "key 型別錯(數字)→ 無可用 key → 格式不符")
    }

    func testKeyParserOneBadEntryDoesNotKillValidSibling() {
        // 一個壞 entry(值非物件)+ 一個合法帳號 → 合法者仍被選出(壞 entry 靜默跳過)
        let json = #"{"broken": "not-an-object", "https://auth.x.ai::ok": {"key": "SURVIVES"}}"#
        guard case .key(let k) = GrokKeyParser.parse(data: body(json), now: now) else {
            return XCTAssertTrue(false, "壞 entry 不得拖垮合法 sibling")
        }
        XCTAssertEqual(k, "SURVIVES")
    }

    func testIssuerExactHostNotSubstring() {
        // r2 luna 安全項:`auth.x.ai.evil.com` 不得因子字串 "x.ai" 被當成 x.ai issuer 而優先。
        // 兩者同 band、同 expiry;唯一差別是 issuer host。舊子字串比對會誤選 EVIL(且其 account 字典序在前);
        // 精確 host 比對須選中真正的 x.ai(GOOD)。
        let future = "2027-01-01T00:00:00Z"
        func pick(_ entries: String...) -> String? {
            guard case .key(let k) = GrokKeyParser.parse(
                data: body("{" + entries.joined(separator: ",") + "}"), now: now) else { return nil }
            return k
        }
        XCTAssertEqual(pick(account("https://auth.x.ai.evil.com::a", key: "EVIL", expires: future),
                            account("https://auth.x.ai::b", key: "GOOD", expires: future)), "GOOD",
                       "auth.x.ai.evil.com 不得偽裝成 x.ai;精確 host 比對選真正 x.ai")
    }

    func testExpiresAtFractionalSecondsUsedInSelection() {
        // GrokISO8601(含小數秒容忍)現由 auth 的 expires_at 選擇使用。兩帳號皆 x.ai、皆未過期;A 的 expiry
        // 帶微秒且較晚,B 不帶且較早。selector 偏好較晚 expiry → 必選 A;若微秒未被解析(→ nil,落 unknown
        // band)則 A 反輸給 B(unexpired)。故選中 A 證明含微秒 expires_at 被正確解析為較晚時刻。
        func pick(_ entries: String...) -> String? {
            guard case .key(let k) = GrokKeyParser.parse(
                data: body("{" + entries.joined(separator: ",") + "}"), now: now) else { return nil }
            return k
        }
        XCTAssertEqual(pick(account("https://auth.x.ai::a", key: "FRAC", expires: "2027-06-01T00:00:00.500000+00:00"),
                            account("https://auth.x.ai::b", key: "PLAIN", expires: "2027-01-01T00:00:00Z")), "FRAC",
                       "含微秒 expires_at 須解析為較晚時刻(unexpired)→ 晚者優先選中")
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
