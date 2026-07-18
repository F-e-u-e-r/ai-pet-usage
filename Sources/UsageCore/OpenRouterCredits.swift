import Foundation

// OpenRouter 預付 credit 餘額監控(opt-in,預設關)—— 純邏輯層。
// 邊界契約(docs/DATA_SOURCES.md「OpenRouter credits」):
//   - 本檔**零網路**:request 建構、回應解析、狀態機、呈現字串全是純函式,
//     由 GUI 層(OpenRouterCreditsChecker)注入真正的 URLSession 執行。
//   - key 只從 opencode 的 auth.json 窄解碼(整檔讀 bytes,僅 `openrouter` 一項會被
//     解碼成物件;其他項目/欄位絕不 materialize)。GUI **不讀** OPENROUTER_API_KEY
//     env(雙審 R1:env 可能悄悄選錯帳號、遮蔽已輪替的 opencode key)。
//   - key 絕不落地、絕不進 log/診斷/匯出;錯誤呈現只走本檔的封閉詞彙,
//     不得插入 localizedDescription / 回應本文。
//   - 誠實守則:remaining 帶正負號如實顯示(不 max(0,·) 假裝歸零);clamp 只用於
//     bar 幾何;totalCredits ≤ 0 顯示固定字句,絕不出現「$0.00 left of $0」。

// MARK: - Key 來源(窄解碼)

public enum OpenRouterKeyParser {
    /// auth.json 大小上限:正常檔僅數百 bytes,超過即拒讀(fail closed)。
    public static let maxAuthFileBytes = 1_048_576

    /// 整檔 bytes 進、只解 `openrouter.{type,key}`;其餘 provider 項目不會被解碼成物件。
    /// 接受條件:`type == "api"`、key 非空、20–512 字、可印 ASCII(無空白/控制字元
    /// —— key 會進 HTTP header,先擋 CR/LF 注入)。不符 → nil(fail closed)。
    public static func parse(data: Data) -> String? {
        guard data.count <= maxAuthFileBytes else { return nil }
        struct Entry: Decodable { var type: String?; var key: String? }
        struct AuthFile: Decodable { var openrouter: Entry? }
        guard let file = try? JSONDecoder().decode(AuthFile.self, from: data),
              let entry = file.openrouter,
              entry.type == "api",
              let key = entry.key else { return nil }
        guard (20...512).contains(key.count),
              key.allSatisfy({ ch in
                  guard let ascii = ch.asciiValue else { return false }
                  return (0x21...0x7E).contains(ascii)   // 可印 ASCII、無空白
              }) else { return nil }
        return key
    }
}

// MARK: - 快照與結果

public struct OpenRouterCreditsSnapshot: Sendable, Equatable {
    /// 帳戶歷來購買的 credit 總額(USD;OpenRouter 回報值,原樣保留)。
    public var totalCredits: Double
    /// 帳戶歷來已用(USD;OpenRouter 回報值,原樣保留)。
    public var totalUsage: Double
    public var fetchedAt: Date

    public init(totalCredits: Double, totalUsage: Double, fetchedAt: Date) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
        self.fetchedAt = fetchedAt
    }

    /// 剩餘 = 購買 − 已用,**帶正負號**(帳戶可小幅透支;負值如實顯示,不假裝 $0)。
    public var remaining: Double { totalCredits - totalUsage }

    /// bar 幾何用的剩餘比例(僅視覺 clamp 0…1);totalCredits ≤ 0 無意義 → nil(無 bar)。
    public var remainingFraction: Double? {
        guard totalCredits > 0 else { return nil }
        return min(1, max(0, remaining / totalCredits))
    }
}

/// 單次抓取的結果(checker 寫入 status;`.noKey`/`.networkError` 由 checker 端判定)。
public enum OpenRouterCreditsOutcome: Sendable, Equatable {
    case success(OpenRouterCreditsSnapshot)
    /// 401/403:key 被拒(opencode 的 key 會過期/輪替)。快照隨之清除 —— 帳號連結已斷,
    /// 舊餘額不得再以「上次值」示人(R1 G3)。
    case keyRejected
    /// 其他非 2xx。
    case serverError
    /// 回應超限 / 非預期 JSON / 缺欄位 / 非信任 host。
    case badReply
    /// 傳輸層失敗(逾時、離線)。錯誤內文不保留。
    case networkError
    /// 找不到可用 key(檔案不存在 / 非 api 型 / 驗證不過)。無 key 即**零網路**。
    case noKey
}

// MARK: - Engine(request 建構 + 回應解析;無網路)

public enum OpenRouterCreditsEngine {
    public static let host = "openrouter.ai"
    public static let creditsURL = URL(string: "https://openrouter.ai/api/v1/credits")!
    /// 回應大小上限:credits 回應僅數十 bytes,超過即視為異常(fail closed)。
    public static let maxResponseBytes = 262_144

    /// 唯一的 request 形狀:GET /api/v1/credits,無 query;key 只進 Authorization header
    ///(絕不進 URL / argv)。標頭僅三項,不夾帶 OS 或用量資料。
    public static func request(key: String, appVersion: String) -> URLRequest {
        var req = URLRequest(url: creditsURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIPetUsage/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        return req
    }

    /// redirect 一律拒絕(session delegate 委派到此;帶著 Authorization 跟隨轉址
    /// 是 key 外洩路徑 —— R1 兩家審查一致)。
    public static func redirectDecision() -> URLRequest? { nil }

    /// 回應必須仍是 https://openrouter.ai,否則整包丟棄(縱深防禦;理論上 redirect 已被拒)。
    public static func isTrustedResponse(url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host == host
    }

    /// 解析回應:2xx + 窄解碼 `{data:{total_credits,total_usage}}`,兩欄皆必填
    /// (缺 → badReply,絕不補 0)。401/403 → keyRejected;其他非 2xx → serverError。
    public static func parseResponse(statusCode: Int, data: Data, now: Date) -> OpenRouterCreditsOutcome {
        if statusCode == 401 || statusCode == 403 { return .keyRejected }
        guard (200..<300).contains(statusCode) else { return .serverError }
        guard data.count <= maxResponseBytes else { return .badReply }
        struct Payload: Decodable {
            struct D: Decodable {
                var total_credits: Double?
                var total_usage: Double?
            }
            var data: D?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let credits = payload.data?.total_credits,
              let usage = payload.data?.total_usage else { return .badReply }
        return .success(OpenRouterCreditsSnapshot(totalCredits: credits, totalUsage: usage, fetchedAt: now))
    }
}

// MARK: - 抓取生命週期閘(純狀態機;GUI checker 的單流/世代決策全走這裡)

/// 單流 + 世代守衛的**純**決策核心(R2 兩家審查的競態類 —— grok F1/F2、codex F1 ——
/// 的回歸鎖)。規則:
///   - 同時最多一個 fetch(`tryBegin` 佔用中回 nil);
///   - `bumpGeneration`(停用/重開)強制釋放佔用 —— 新啟用的立即抓取不必等舊 fetch 退場;
///   - 舊 fetch 的 `end` 只在仍持有時才釋放(不誤清新 fetch 的佔用);
///   - 舊 fetch 的結果以 `shouldCommit` 判定(世代不符 = 晚到 → 丟棄)。
public struct OpenRouterFetchGate: Sendable, Equatable {
    public private(set) var generation = 0
    public private(set) var activeGeneration: Int?

    public init() {}

    /// 停用/重啟:世代 +1、強制釋放單流佔用。
    public mutating func bumpGeneration() {
        generation &+= 1
        activeGeneration = nil
    }

    /// 嘗試開始 fetch:成功回傳本次的 generation token;已有進行中 → nil。
    public mutating func tryBegin() -> Int? {
        guard activeGeneration == nil else { return nil }
        activeGeneration = generation
        return generation
    }

    /// fetch 結束(不論成敗):只在仍持有佔用時釋放。
    public mutating func end(_ token: Int) {
        if activeGeneration == token { activeGeneration = nil }
    }

    /// 此 token 的結果是否可寫入狀態(世代未變才算數)。
    public func shouldCommit(_ token: Int) -> Bool {
        token == generation
    }
}

// MARK: - 狀態 + 呈現(封閉詞彙)

public struct OpenRouterCreditsStatus: Sendable, Equatable {
    /// 最後一次成功的快照;keyRejected / noKey / 停用時清除。
    public var snapshot: OpenRouterCreditsSnapshot?
    public var lastAttemptAt: Date?
    public var lastOutcome: OpenRouterCreditsOutcome?

    public init(snapshot: OpenRouterCreditsSnapshot? = nil,
                lastAttemptAt: Date? = nil,
                lastOutcome: OpenRouterCreditsOutcome? = nil) {
        self.snapshot = snapshot
        self.lastAttemptAt = lastAttemptAt
        self.lastOutcome = lastOutcome
    }

    /// UI 所有表面共用的呈現值。字串**只**由此產生(封閉詞彙;任何錯誤都不得
    /// 插入執行期任意文字)。`stale` = 快照超齡或最近一次嘗試失敗。
    public struct Presentation: Sendable, Equatable {
        /// 面板列主文字:「$29.57 left」/「over by $0.12」/ 固定狀態句。
        public var primary: String
        /// 補充:「of $40.00」;錯誤但有舊快照時為「last $29.57 · 2h」。
        public var detail: String?
        /// 快照年齡(「3m」);無快照 → nil。
        public var age: String?
        public var stale: Bool
        /// 剩餘比例 bar(中性 teal,無警戒色 —— 預付餘額不是配額);nil = 不畫。
        public var barFraction: Double?
        /// tooltip / a11y 全句(computed 值不冠「official」;來源歸因 + recency)。
        public var tooltip: String
        /// 泡泡第 0 頁(用量頁)行;錯誤 / 無快照 → nil(整行省略,不顯示假值)。
        public var bubbleUsageLine: String?
        /// 泡泡第 2 頁(資料頁)行:狀態 / 來源 + 年齡。
        public var bubbleDataLine: String?
    }

    public func presentation(now: Date, staleAfterMinutes: Int = 30) -> Presentation {
        if let snap = snapshot {
            let ageSeconds = now.timeIntervalSince(snap.fetchedAt)
            let ageText = Self.compactAge(seconds: ageSeconds)
            let attemptFailed = lastOutcome != nil && !Self.isSuccess(lastOutcome!)
            let stale = attemptFailed || ageSeconds > Double(staleAfterMinutes) * 60
            let hasCredits = snap.totalCredits > 0
            let left = Self.fmtUSD(snap.remaining)

            // 失敗分支**先於**零額度分支(R2 codex F4):零額度快照 + 之後刷新失敗,
            // 不得繼續宣稱「no prepaid credits」而藏住失敗事實。
            if attemptFailed {
                let line = Self.stateLine(for: lastOutcome!)
                let lastKnown = hasCredits ? "last \(left)" : "no prepaid credits"
                return Presentation(
                    primary: line, detail: "\(lastKnown) · \(ageText)",
                    age: ageText, stale: true, barFraction: nil,
                    tooltip: "\(line). Last known: \(hasCredits ? "balance \(left)" : "no prepaid credits"), "
                        + "from OpenRouter-reported totals \(ageText) ago.",
                    bubbleUsageLine: nil,
                    bubbleDataLine: "OR \(Self.shortState(for: lastOutcome!)) · \(ageText)")
            }

            let staleSuffix = stale ? " · \(ageText)" : ""
            guard hasCredits else {
                // 有官方回應但沒有預付額度:固定字句,絕不渲染「$0.00 left of $0」。
                // 這是成功取得的資料 → 泡泡用量頁照樣呈現(R2 codex F4)。
                return Presentation(
                    primary: "no prepaid credits", detail: nil, age: ageText, stale: stale,
                    barFraction: nil,
                    tooltip: "OpenRouter reports no prepaid credits on this account (as of \(ageText) ago).",
                    bubbleUsageLine: "OR no credits\(staleSuffix)",
                    bubbleDataLine: "OR no credits · \(ageText)")
            }

            let primary = snap.remaining < 0 ? "over by \(Self.fmtUSD(-snap.remaining))" : "\(left) left"
            return Presentation(
                primary: primary,
                detail: "of \(Self.fmtUSD(snap.totalCredits))",
                age: ageText, stale: stale,
                barFraction: snap.remainingFraction,
                tooltip: "OpenRouter credits: calculated from OpenRouter-reported totals — "
                    + "\(Self.fmtUSD(snap.totalCredits)) purchased, \(Self.fmtUSD(snap.totalUsage)) used, "
                    + "\(left) left. As of \(ageText) ago.",
                bubbleUsageLine: "OR \(primary)\(staleSuffix)",
                bubbleDataLine: "OR reported · \(ageText)")
        }

        // 無快照:純狀態(loading / noKey / 各式錯誤)。
        let line: String
        let short: String
        switch lastOutcome {
        case nil:
            line = "checking…"; short = "checking"
        case .some(let outcome):
            line = Self.stateLine(for: outcome)
            short = Self.shortState(for: outcome)
        }
        return Presentation(
            primary: line, detail: nil, age: nil, stale: lastOutcome != nil,
            barFraction: nil, tooltip: "OpenRouter credits: \(line).",
            bubbleUsageLine: nil,
            bubbleDataLine: lastOutcome == nil ? nil : "OR \(short)")
    }

    private static func isSuccess(_ o: OpenRouterCreditsOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }

    /// 面板用固定狀態句(封閉詞彙 —— 僅此五句 + 數字句)。
    static func stateLine(for outcome: OpenRouterCreditsOutcome) -> String {
        switch outcome {
        case .success: return "ok"                                  // 不會單獨呈現
        case .noKey: return "no key — log in with opencode"
        case .keyRejected: return "key rejected — re-log in with opencode"
        case .serverError, .networkError: return "can't reach OpenRouter"
        case .badReply: return "unexpected reply from OpenRouter"
        }
    }

    /// 泡泡資料頁用短狀態詞。
    static func shortState(for outcome: OpenRouterCreditsOutcome) -> String {
        switch outcome {
        case .success: return "ok"
        case .noKey: return "no key"
        case .keyRejected: return "key rejected"
        case .serverError, .networkError: return "unreachable"
        case .badReply: return "bad reply"
        }
    }

    /// 金額固定 2 位小數;負值前置「-」。(數千美元不加千分位 —— 面板寬度優先,測試釘住。)
    public static func fmtUSD(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        return String(format: "%@$%.2f", sign, abs(value))
    }

    /// 年齡壓縮:<60s「now」、<1h「Nm」、<24h「Nh」、其餘「Nd」。
    public static func compactAge(seconds: TimeInterval) -> String {
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
