import Foundation

// F3 Grok 官方額度(Phase 1;boundary 修訂 #73 已核准)。本檔是**純邏輯層**:
// request 構造、narrow key 解碼、versioned decoder、401 重試門檻 —— 零 I/O、零網路、
// 時刻注入,GUI 接線層(GrokQuotaChecker)只負責 session/輪詢/狀態曝露。
// 契約:docs/PHASE1_DATA_CONTRACT.internal.md v5(§2 credits 列、§4 Grok 列、§5 狀態機);
// 硬線:token 永不寫回/refresh(Grok refresh 會輪替並弄掉使用者 CLI 登入)、
// 永不持久化、錯誤封閉詞彙、consume 類端點不存在於本 provider。

// MARK: - ISO8601(容忍含/不含小數秒)

/// 真實 Grok 時戳帶微秒(如 `2026-08-13T13:58:47.849415+00:00`);預設 `ISO8601DateFormatter`
/// 不含 `.withFractionalSeconds` 會把它解成 nil。每次呼叫新建 formatter —— 無共享可變狀態
/// (避免資料競爭);此路徑低頻,配置成本可忽略。現由 auth 的 expires_at 選擇解析使用(Track A)。
fileprivate enum GrokISO8601 {
    static func date(from s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

// MARK: - Key 解碼(narrow;真實 `~/.grok/auth.json` = OIDC 憑證庫,token 巢狀)

public enum GrokKeyParser {
    public static let maxAuthFileBytes = 1_048_576   // >1MB 拒讀(同 opencode ‡ 列)

    /// 解析三分(F3 hotfix;live-validated 2026-08-09,見 micro-brief):
    /// - `.key`:選出的可用 session token(narrow:僅 `key`/`expires_at` 曾被 materialize)。
    /// - `.malformed`:非 JSON / 非「物件之字典」/ 超限 → transientError(可能寫入中途;可重試)。
    /// - `.formatUnrecognized`:合法 JSON 物件但無任一 entry 產出可用 key(含空 `{}`)→ auth
    ///   格式不符;呼叫端映射到既有 `.schemaBreaking`(凍結、零外呼、升級/手動才 re-probe)。
    public enum Result: Equatable, Sendable {
        case key(String)
        case malformed
        case formatUnrecognized
    }

    /// 真實 shape:頂層 = `"<oidc_issuer>::<account-id>"` → 帳號物件 的字典;token 巢狀為 `key`。
    /// narrow:自訂 init **只**讀 `key` + `expires_at`;`refresh_token` / email / 其他 profile
    /// PII 因未列於 CodingKeys 而永不 materialize(且這兩欄型別怪異也 try? 成 nil,不拋錯)。
    private struct Entry: Decodable {
        let key: String?
        let expiresAt: String?
        private enum CodingKeys: String, CodingKey { case key; case expiresAt = "expires_at" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)   // 非 keyed(值為字串/陣列/數字/null)→ throw
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            expiresAt = try? c.decodeIfPresent(String.self, forKey: .expiresAt)
        }
    }

    /// per-entry 容錯:單一壞 entry 不得使整個 store 解碼拋錯(合法 sibling 不被誤殺)。
    private struct Lenient: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    private struct Candidate { let account: String; let key: String; let expiry: Date? }

    public static func parse(data: Data, now: Date) -> Result {
        guard data.count <= maxAuthFileBytes else { return .malformed }
        guard let store = try? JSONDecoder().decode([String: Lenient].self, from: data) else {
            return .malformed   // 非 JSON、或非「物件之字典」(陣列/scalar/壞)→ transient
        }
        var candidates: [Candidate] = []
        for (account, wrap) in store {
            guard let e = wrap.entry, let k = e.key, !k.isEmpty else { continue }
            candidates.append(Candidate(account: account, key: k,
                                        expiry: e.expiresAt.flatMap(GrokISO8601.date(from:))))
        }
        guard let best = candidates.min(by: { sortKey($0, now: now) < sortKey($1, now: now) }) else {
            return .formatUnrecognized   // 合法物件但無可用 key(含空 {})→ 格式不符(非 transient)
        }
        return .key(best.key)
    }

    /// deterministic selector(micro-brief §1):字典序 tuple —— 未過期(0)< 未知(1)< 過期(2);
    /// x.ai issuer 優先;晚 `expires_at` 優先;最後 account 字典序作決定性 tie-break。缺/壞
    /// `expires_at` = 未知(band 1),**絕不**判過期。
    private static func sortKey(_ c: Candidate, now: Date) -> (Int, Int, Double, String) {
        let band: Int
        if let e = c.expiry { band = e > now ? 0 : 2 } else { band = 1 }
        let issuer = isXaiIssuer(c.account) ? 0 : 1
        let negExpiry = c.expiry.map { -$0.timeIntervalSince1970 } ?? 0
        return (band, issuer, negExpiry, c.account)
    }

    /// issuer host **精確**比對(不用子字串:`auth.x.ai.evil.com` 不得偽裝成 x.ai —— r2 luna 安全項)。
    /// account key 形如 `<issuer-url>::<account-id>`;取 issuer 段解析 host,須為 `x.ai` 或其子網域。
    private static func isXaiIssuer(_ account: String) -> Bool {
        let issuer = account.components(separatedBy: "::").first ?? account
        guard let host = URLComponents(string: issuer)?.host?.lowercased() else { return false }
        return host == "x.ai" || host.hasSuffix(".x.ai")
    }
}

// MARK: - 快照與結果(封閉詞彙)

/// 額度快照(memory-only;絕不持久化 —— boundary #73 回應資料分類)。
public struct GrokQuotaSnapshot: Sendable, Equatable {
    public var usedPercent: Double            // 顯示值(≤100;provider-reported)
    /// raw 值 >100 時為 true(owner 裁示:clamp 只是顯示強健性,**不得把 upstream
    /// anomaly 靜默變成「正常 100%」**—— UI 據此標示,F17 可記 dataQuality)。
    public var reportedPercentOverflow: Bool
    public var periodStart: Date?
    public var periodEnd: Date?               // = 重置時間
    public var planName: String?
    public var fetchedAt: Date

    public init(usedPercent: Double, reportedPercentOverflow: Bool = false,
                periodStart: Date?, periodEnd: Date?,
                planName: String?, fetchedAt: Date) {
        self.usedPercent = usedPercent
        self.reportedPercentOverflow = reportedPercentOverflow
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.planName = planName
        self.fetchedAt = fetchedAt
    }
}

/// 抓取結果(封閉;UI 文案與 F17 事件都由此映射,原始錯誤內文永不外洩)。
public enum GrokQuotaOutcome: Sendable, Equatable {
    case success(GrokQuotaSnapshot)
    case noUsageData              // 有效 200 但無可用 usage %(欄位實測時有時無)→ 軟降級,非 kill、不造數
    case noKey                    // 檔案不存在(未登入)→ presence .unavailable(notLoggedIn)
    case credentialUnreadable     // 檔在但讀不了/壞 → transientError;絕不誘導重登(契約 §4)
    case keyRejected              // 401 → health .authExpired(重登提示;§4 重試門檻)
    case rateLimited(retryAfterSeconds: Double?)   // 429(Retry-After 有效才帶值)
    case schemaBreaking           // root 非物件等結構破壞 → 立即 schemaKilled(契約 §5;缺/壞 % 改走 .noUsageData/.badReply)
    case invalidBody              // JSON 壞 → ×3 連續才 schemaKilled
    case endpointGone             // 404/410(端點消失)→ ×3 連續才 schemaKilled(獨立計數)
    case serverError              // 5xx → transientError(退避)
    case badReply                 // 超限/非 JSON content/不可信回應 → transientError
    case networkError             // timeout/DNS/TLS → transientError

    /// F17 狀態機事件映射(單一真相:GUI 不得自行翻譯)。
    public var observationEvent: SourceObservationEvent {
        switch self {
        case .success, .noUsageData: return .success   // 有效 200 = 源健康;無 % 只是資料暫缺,非源故障
        case .keyRejected: return .authRejected
        case .rateLimited: return .rateLimited
        case .schemaBreaking: return .schemaBreaking
        case .invalidBody: return .invalidBody
        case .endpointGone: return .endpointGone
        case .noKey, .credentialUnreadable, .serverError, .badReply, .networkError: return .transportFailure
        }
    }
}

// MARK: - Engine(request / response;純函數)

public enum GrokQuotaEngine {
    public static let maxResponseBytes = 262_144
    public static let host = "cli-chat-proxy.grok.com"

    /// 唯一 egress(boundary #73):GET /v1/billing?format=credits。
    /// headers:Authorization Bearer(session token)+ X-XAI-Token-Auth: xai-grok-cli
    /// (CLI 自身的識別 header,非 UA 冒充;無 OS 字串、無用量資料)。
    public static func request(key: String, appVersion: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host)/v1/billing?format=credits")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIPetUsage/\(appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// redirect 一律拒絕(Authorization 絕不跟轉址走;同 OpenRouter 既審決策)。
    public static func redirectDecision() -> URLRequest? { nil }

    /// 回應必須仍來自唯一 host(縱深防禦;redirect 已拒,此為第二道)。
    public static func isTrustedResponse(url: URL?) -> Bool {
        url?.host == host && url?.scheme == "https"
    }

    /// versioned decoder(契約 §5 + F3 hotfix 分類):
    /// - root 非物件 → schemaBreaking(唯一 evidence-backed 結構破壞;立即 kill)
    /// - root 含 `error`(非 null)→ .badReply(明確 error-envelope,無論 config 是否在)
    /// - 無 `config` 物件 → .badReply(無法辨識/error;transient,不清 401 門檻、不 kill)
    /// - 有 `config` 物件 → .noUsageData —— creditUsagePercent 已證**非** weekly quota(見下),Track A 不 render
    /// - JSON 壞 → invalidBody(×3 才 kill,狀態機管);未知欄位 = additive → 容忍。
    public static func parseResponse(statusCode: Int, data: Data, now: Date) -> GrokQuotaOutcome {
        switch statusCode {
        case 200:
            break
        case 401:
            return .keyRejected
        case 429:
            return .rateLimited(retryAfterSeconds: nil)   // Retry-After 由呼叫端以 header 補
        case 500...599:
            return .serverError
        case 404, 410:
            return .endpointGone   // 端點消失 = schema 級變更(契約 §5:×3 → kill,獨立計數)
        default:
            return .badReply   // 403/400/408/其他 → transientError 類(不誘導重登)
        }
        guard data.count <= maxResponseBytes else { return .badReply }
        guard let anyRoot = try? JSONSerialization.jsonObject(with: data) else {
            return .invalidBody          // JSON 壞 → ×3 升級
        }
        guard let root = anyRoot as? [String: Any] else {
            return .schemaBreaking       // 合法 JSON 但非物件 = 結構型別錯 → 立即 kill(r1 ultra#6)
        }
        // 明確 error-envelope(200 但含非-null `error`)→ .badReply,無論 config 是否在。
        if let err = root["error"], !(err is NSNull) { return .badReply }
        // 必須是可辨識的 billing envelope(有 `config` 物件);無 config → .badReply(transient:不標健康、
        // 不清 401 門檻、保留 last-good、不 kill)。
        guard root["config"] is [String: Any] else { return .badReply }
        // Track B ground truth(2026-08-10):`creditUsagePercent` = credit/product 用量,**不是** Grok
        // weekly quota —— 實測同 weekly window 內 100%→absent;官方 `grok /usage` 另有 weekly signal
        // (0% + reset)。故 Track A 一律**不**以 creditUsagePercent 驅動 weekly-% UI(無論在否)→
        // .noUsageData(honestly unavailable);真正 weekly substrate 由 REDESIGN(定位 grok /usage 之來源)接。
        // Track A 只撤除此已證偽的 semantic mapping,不定位/實作新 source(見 f3-grok-quota-real-schema memo)。
        return .noUsageData
    }

    // NOTE:creditUsagePercent 已於 Track A 撤除為 weekly-quota source(見 parseResponse 註)。原本用於
    // 解析該 % 與 period 的 asDouble/usablePercent/asDate 亦一併移除;REDESIGN 接真正 grok /usage 來源時
    // 再按該來源實際形狀重寫解析(GrokISO8601 保留,現由 auth 的 expires_at 選擇使用)。
}

// MARK: - credential 讀取結果(契約 §4 生命週期表的三分;r1 三鏡:全塌 noKey 會把
// 「檔在但壞」誤導成重登)

public enum KeyLoadResult: Equatable, Sendable {
    case key(String)              // 合法讀出並選出可用 token
    case fileMissing              // 檔案不存在(未登入)→ presence .unavailable(notLoggedIn)
    case unreadable               // 檔在但讀不了/超限/JSON 壞/非物件 → transientError,絕不顯重登
    case authFormatUnrecognized   // 合法 JSON 物件但無可用 key(含空 {})→ 格式不符(呼叫端映射 schemaBreaking)
}

// MARK: - 顯示詞彙(封閉;UI 逐字使用,絕不含 token / 原始錯誤內文)

public extension GrokQuotaOutcome {
    /// 狀態句(無 snapshot 可顯時的整寬句;沿 OpenRouter 兩行呈現慣例)。
    var stateLine: String {
        switch self {
        case .success: return ""
        case .noUsageData: return "no usage data"
        case .noKey: return "not logged in — run grok once"
        case .credentialUnreadable: return "credential file unreadable — will retry"
        case .keyRejected: return "login expired — run grok once to re-log in"
        case .rateLimited: return "rate limited — will retry"
        case .schemaBreaking, .invalidBody, .endpointGone: return "provider changed format"
        case .serverError, .badReply, .networkError: return "can't reach Grok"
        }
    }
}

// MARK: - Checker 純決策核心(owner 六 lifecycle case 的可測落點)

/// GUI 殼(GrokQuotaChecker)只執行本 policy 的決策:toggle-off 零 egress、401 門檻
/// (手動 bypass)、結果 → F17 狀態機。單流與世代守衛(single-flight / late-response
/// suppression)復用 shipped 的 `OpenRouterFetchGate`(泛用純件,自有測試)。
public struct GrokQuotaPolicy: Sendable, Equatable {
    public private(set) var credGate = CredentialChangeGate()
    public private(set) var machine = SourceHealthMachine.State()

    public enum FetchDecision: Equatable, Sendable {
        case proceed
        case skipDisabled              // toggle off → 零 egress(結構性)
        case skipCredentialUnchanged   // 401 在案且檔未變 → 永久 skip(零外呼)
    }

    public init() {}

    /// tick / 手動時的外呼決策。手動 Refresh = 契約明文的第二條門檻(bypass credGate,
    /// 但**不** bypass enabled —— off 下手動也零 egress)。
    public func decision(enabled: Bool, currentStat: CredentialChangeGate.FileStat,
                         isManual: Bool) -> FetchDecision {
        guard enabled else { return .skipDisabled }
        if isManual { return .proceed }
        return credGate.shouldAttempt(currentStat: currentStat) ? .proceed : .skipCredentialUnchanged
    }

    /// 結果落地:F17 狀態機前進;401 → 以**抓取當下**的檔案身分上門檻(下一次仍 401 →
    /// 立即以新身分重新 blocked);成功 → 門檻解除。其他失敗不動門檻(401 門檻只管 401)。
    /// `statAtFetch = nil` 表示身分無法確定(read 前後 stat 不一致 = 檔案動盪中;
    /// r2 P6):401 **不上門檻**(下輪以新檔自然重試),machine 照常前進。
    public mutating func apply(outcome: GrokQuotaOutcome, statAtFetch: CredentialChangeGate.FileStat?) {
        machine = SourceHealthMachine.step(machine, outcome.observationEvent)
        switch outcome {
        case .keyRejected: if let stat = statAtFetch { credGate.noteRejected(stat: stat) }
        case .success, .noUsageData: credGate.clear()   // 兩者皆為 200(認證成功)→ 解除 401 門檻
        default: break
        }
    }

    /// 重啟 hydrate(r2 P7):persisted kill 存在且同版本 → 恢復凍結態(零外呼),
    /// 不經任何觀測事件。
    public mutating func restoreKilled() {
        machine = SourceHealthMachine.State(health: .schemaKilled)
    }

    /// schemaKilled 的顯式重試(app 版本變更自動一次 / 手動 re-enable;呼叫端 gate toggle-on)。
    public mutating func reactivate(probeOutcome: GrokQuotaOutcome, statAtFetch: CredentialChangeGate.FileStat?) {
        machine = SourceHealthMachine.reactivate(machine, probeResult: probeOutcome.observationEvent)
        if case .keyRejected = probeOutcome, let stat = statAtFetch { credGate.noteRejected(stat: stat) }
        if case .success = probeOutcome { credGate.clear() }
        if case .noUsageData = probeOutcome { credGate.clear() }   // 有效 200(認證成功)→ 解除門檻
    }
}

// MARK: - 401 重試門檻(契約 §4;純值語義)

/// 「401 後,API 外呼的唯一門檻 = credential 檔 mtime/size 變更、或使用者手動 Refresh ——
/// 無時間例外:檔案未變且無手動動作 → 永久 skip(零外呼、零 401 累積)。」
/// 呼叫端每 tick 對 auth 檔 cheap stat 後詢問本 gate;變更或手動 → 立即重試。
public struct CredentialChangeGate: Equatable, Sendable {
    public struct FileStat: Equatable, Sendable {
        public var mtime: Date?
        public var size: Int64?
        public var exists: Bool

        public init(mtime: Date?, size: Int64?, exists: Bool) {
            self.mtime = mtime
            self.size = size
            self.exists = exists
        }
    }

    private var rejectedAtStat: FileStat?   // 最近一次 401 時的檔案身分;nil = 無 401 待門

    public init() {}

    /// 401 發生時記錄當下檔案身分(呼叫端在收到 keyRejected 後呼叫)。
    public mutating func noteRejected(stat: FileStat) {
        rejectedAtStat = stat
    }

    /// 呼叫端於成功(或等效的有效 200,如 .noUsageData)時呼叫本函式解除門檻;其他結果不呼叫,門檻續留。
    public mutating func clear() {
        rejectedAtStat = nil
    }

    /// 這一 tick 可否外呼:無 401 在案 → 可;有 → 僅當檔案身分變更(mtime/size/存在性
    /// 任一不同)。手動 Refresh 由呼叫端繞過本 gate(契約明文的第二條門檻)。
    public func shouldAttempt(currentStat: FileStat) -> Bool {
        guard let rejected = rejectedAtStat else { return true }
        return currentStat != rejected
    }
}
