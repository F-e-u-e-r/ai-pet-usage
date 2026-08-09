import Foundation

// F3 Grok 官方額度(Phase 1;boundary 修訂 #73 已核准)。本檔是**純邏輯層**:
// request 構造、narrow key 解碼、versioned decoder、401 重試門檻 —— 零 I/O、零網路、
// 時刻注入,GUI 接線層(GrokQuotaChecker)只負責 session/輪詢/狀態曝露。
// 契約:docs/PHASE1_DATA_CONTRACT.internal.md v5(§2 credits 列、§4 Grok 列、§5 狀態機);
// 硬線:token 永不寫回/refresh(Grok refresh 會輪替並弄掉使用者 CLI 登入)、
// 永不持久化、錯誤封閉詞彙、consume 類端點不存在於本 provider。

// MARK: - Key 解碼(narrow;複製 OpenRouterKeyParser 既審模式)

public enum GrokKeyParser {
    public static let maxAuthFileBytes = 1_048_576   // >1MB 拒讀(同 opencode ‡ 列)

    /// `~/.grok/auth.json` 的唯一被解碼欄位:頂層 `key`(session token)。
    /// 其他任何欄位(refresh token 等)**永不 materialize** —— narrow decoder 只建這一欄。
    private struct AuthFile: Decodable { let key: String? }

    public static func parse(data: Data) -> String? {
        guard data.count <= maxAuthFileBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(AuthFile.self, from: data),
              let key = decoded.key, !key.isEmpty else { return nil }
        return key
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
    case noKey                    // 檔案不存在(未登入)→ presence .unavailable(notLoggedIn)
    case credentialUnreadable     // 檔在但讀不了/壞 → transientError;絕不誘導重登(契約 §4)
    case keyRejected              // 401 → health .authExpired(重登提示;§4 重試門檻)
    case rateLimited(retryAfterSeconds: Double?)   // 429(Retry-After 有效才帶值)
    case schemaBreaking           // 必要欄位缺/型別錯 → 立即 schemaKilled(契約 §5)
    case invalidBody              // JSON 壞 → ×3 連續才 schemaKilled
    case endpointGone             // 404/410(端點消失)→ ×3 連續才 schemaKilled(獨立計數)
    case serverError              // 5xx → transientError(退避)
    case badReply                 // 超限/非 JSON content/不可信回應 → transientError
    case networkError             // timeout/DNS/TLS → transientError

    /// F17 狀態機事件映射(單一真相:GUI 不得自行翻譯)。
    public var observationEvent: SourceObservationEvent {
        switch self {
        case .success: return .success
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

    /// versioned decoder(契約 §5):必要欄位 = `creditUsagePercent`(數值)。
    /// 週期起訖/方案名為選配(缺 → nil,不 kill);**未知欄位 = additive → 容忍**;
    /// 必要欄位缺或型別錯 = breaking;JSON 壞 = invalidBody(×3 才 kill,由狀態機管)。
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
        // 必要欄位:creditUsagePercent(頂層或 config 下;實抓 shape 為 config 巢狀,
        // 頂層作為容錯別位 —— 兩處都缺/非數值 = breaking)。
        let config = root["config"] as? [String: Any]
        let rawPercent = (config?["creditUsagePercent"] ?? root["creditUsagePercent"])
        guard let percent = asDouble(rawPercent), percent.isFinite, percent >= 0 else {
            return .schemaBreaking
        }
        let period = (config?["currentPeriod"] ?? root["currentPeriod"]) as? [String: Any]
        let snapshot = GrokQuotaSnapshot(
            usedPercent: min(percent, 100),
            reportedPercentOverflow: percent > 100,   // anomaly 不靜默(owner)
            periodStart: asDate(period?["start"]),
            periodEnd: asDate(period?["end"]),
            planName: (config?["plan"] ?? root["plan"]) as? String,
            fetchedAt: now)
        return .success(snapshot)
    }

    private static func asDouble(_ v: Any?) -> Double? {
        if v is Bool { return nil }   // JSON true/false 經 NSNumber 橋接不得變 1/0(r1 三鏡)
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }

    /// 週期時戳:epoch 秒/毫秒數值或 ISO8601 字串皆容忍(additive-tolerant;解不出 → nil)。
    private static func asDate(_ v: Any?) -> Date? {
        if let s = v as? String { return ISO8601DateFormatter().date(from: s) }
        if let d = asDouble(v) {
            // 合理性切分:> 10^12 視為毫秒
            return Date(timeIntervalSince1970: d > 1_000_000_000_000 ? d / 1000 : d)
        }
        return nil
    }
}

// MARK: - credential 讀取結果(契約 §4 生命週期表的三分;r1 三鏡:全塌 noKey 會把
// 「檔在但壞」誤導成重登)

public enum KeyLoadResult: Equatable, Sendable {
    case key(String)          // 合法讀出
    case fileMissing          // 檔案不存在 → presence .unavailable(notLoggedIn)
    case unreadable           // 檔在但讀不了/超限/JSON 壞/key 欄缺空 → transientError,絕不顯重登
}

// MARK: - 顯示詞彙(封閉;UI 逐字使用,絕不含 token / 原始錯誤內文)

public extension GrokQuotaOutcome {
    /// 狀態句(無 snapshot 可顯時的整寬句;沿 OpenRouter 兩行呈現慣例)。
    var stateLine: String {
        switch self {
        case .success: return ""
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
        case .success: credGate.clear()
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

    /// 成功或任何非 401 結果 → 門檻解除(下輪照常)。
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
