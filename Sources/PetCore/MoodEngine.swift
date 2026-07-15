import Foundation
import UsageCore

/// 心情引擎:把 DashboardState + 寵物狀態濃縮成單一 mood 與動畫強度。
/// 寵物只消費正規化資料,完全不知道 provider 細節(規格要求)。
public enum MoodEngine {

    public struct Result: Equatable, Sendable {
        public var mood: PetMood
        /// 動畫速度倍率(1 = 平常;燃燒率高 → 更快、更躁動)。
        public var animationSpeed: Double
        /// 一句話的狀態摘要(泡泡與報告用)。
        public var summary: String
        /// 「為何是這個心情」——逐分支的具體觸發原因(如「Idle 47 min」「CC 5h is estimated at 85%」)。
        /// 額度相關原因一律帶 provenance(provider-reported / estimated / stale),避免讓估計值看起來像官方。
        /// 用於 Dashboard 卡、報告、a11y(空間充足)。
        public var reason: String
        /// 極窄的浮動泡泡用的**精簡**原因(≈84pt 寬、字級固定)。誠實守則:estimated/stale 的百分比
        /// 一律帶標記(`~…% est` / `…% stale`),絕不裸露 %;provider-reported 是官方真值可裸露。
        public var shortReason: String

        public init(mood: PetMood, animationSpeed: Double, summary: String,
                    reason: String, shortReason: String = "") {
            self.mood = mood
            self.animationSpeed = animationSpeed
            self.summary = summary
            self.reason = reason
            self.shortReason = shortReason
        }
    }

    public static func evaluate(dashboard: DashboardState, pet: PetStateData,
                                warnThreshold: Double, now: Date = Date()) -> Result {
        let limits = dashboard.limitStates
        let snapshots = dashboard.snapshots

        let fivePercents = limits.compactMap { $0.fiveHour.usedPercent }
        let weeklyPercents = limits.compactMap { $0.weekly.usedPercent }
        let worstFive = fivePercents.max()
        let worstWeekly = weeklyPercents.max()
        let anyExhausted = limits.contains { $0.warning == .exhausted }
        let anyError = snapshots.contains { $0.status == .error }
        let anyStale = snapshots.contains { $0.status == .stale }
        let noProviders = snapshots.isEmpty
        let allNoData = !snapshots.isEmpty && snapshots.allSatisfy {
            $0.status == .noData || $0.status == .unavailable
        }
        let lastEventAt = limits.compactMap(\.lastEventAt).max()
        let soonestExhaustion = limits.compactMap(\.projectedExhaustionAt).min()

        // 動畫強度:預計 90 分鐘內耗盡 → 焦躁加速
        var speed = 1.0
        if let soonest = soonestExhaustion {
            let minutes = soonest.timeIntervalSince(now) / 60
            if minutes < 30 { speed = 2.0 }
            else if minutes < 90 { speed = 1.5 }
        }

        // 每家 provider 各自的 5h 百分比都列出(使用者要求同時看到 Claude 與 Codex)。
        // summary 會進匯出報告(petSummary)—— 百分比必須帶信度標記,估算/陳舊值不得
        // 裸露成官方數字(codex SEV1 round-2;標記樣式與 bubbleQuota 同一套)。
        let providerParts = limits.map { st -> String in
            let code = shortProviderCode(st.providerId)
            if st.fiveHour.idle { return "\(code) idle" }
            if let p = st.fiveHour.usedPercent {
                let pct = Int(p)
                switch st.fiveHour.confidence {
                case .high: return "\(code) \(pct)%"
                case .estimated: return "\(code) ~\(pct)% est"
                case .stale: return "\(code) \(pct)% stale"
                case .unknown: return "\(code) \(pct)%?"
                }
            }
            return "\(code) —"
        }
        let head = providerParts.isEmpty ? "no providers" : providerParts.joined(separator: " · ")
        let summary = "\(head) · burn \(ReportGenerator.fmtTokens(Int(dashboard.burnRateTokensPerHour)))/h"

        let warnPct = Int(warnThreshold.rounded())
        // 額度來源的可信度(provenance):估計值絕不呈現得像官方(cross-model SEV1)。
        func provenance(_ c: Confidence) -> String {
            switch c {
            case .high: return "provider-reported"
            case .estimated: return "estimated"
            case .stale: return "stale"
            case .unknown: return "unverified"
            }
        }
        // 觸發某窗 warning 的 provider:取該窗 usedPercent 最大者;平手以 providerId 穩定排序。
        func trigger(_ window: (ProviderLimitState) -> LimitWindowState) -> (code: String, pct: Int, conf: Confidence)? {
            let hit = limits
                .compactMap { l -> (ProviderLimitState, Double)? in
                    guard let p = window(l).usedPercent, p >= warnThreshold else { return nil }
                    return (l, p)
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.providerId < $1.0.providerId }
                .first
            guard let (l, p) = hit else { return nil }
            return (shortProviderCode(l.providerId), Int(p.rounded()), window(l).confidence)
        }
        // 某 provider「較嚴重的窗」(usedPercent 較高者)+ 其可信度 —— exhausted 原因用。
        // pct 回傳**原始 Double**:排名須用原始值(99.5% 與 100% 四捨五入後皆 100,會讓 tie-break
        // 誤選 provider,codex SEV1);顯示時才 round。
        func worstWindow(_ l: ProviderLimitState) -> (window: String, pct: Double, conf: Confidence)? {
            let f = l.fiveHour.usedPercent
            let w = l.weekly.usedPercent
            if let f, f >= (w ?? -1) { return ("5-hour", f, l.fiveHour.confidence) }
            if let w { return ("weekly", w, l.weekly.confidence) }
            return nil
        }
        // 泡泡用的精簡額度字串(誠實守則):estimated → `~N% est`、stale → `N% stale`(**絕不裸露 %**);
        // provider-reported 是官方真值,可裸露 `N%`。窗名縮寫 5-hour→5h、weekly→wk。
        func bubbleQuota(_ code: String, _ win: String, _ pct: Int, _ c: Confidence, suffix: String = "") -> String {
            let w = win == "5-hour" ? "5h" : (win == "weekly" ? "wk" : win)
            switch c {
            case .high: return "\(code) \(w) \(pct)%\(suffix)"
            case .estimated: return "\(code) \(w) ~\(pct)% est\(suffix)"
            case .stale: return "\(code) \(w) \(pct)% stale\(suffix)"
            case .unknown: return "\(code) \(w) \(pct)%?\(suffix)"
            }
        }

        // 優先序(高 → 低)。每個分支同時給 reason(完整,Dashboard/報告/a11y)與 shortReason(泡泡)。
        if let until = pet.eatingUntil, until > now {
            // 免費 kibble 也走 eating —— 不寫死「a treat」。
            return Result(mood: .eating, animationSpeed: 1.2, summary: summary,
                          reason: "Eating now.", shortReason: "eating now")
        }
        if let until = pet.celebrationUntil, until > now {
            // 慶祝要署名(哪家 provider 的哪個窗)+ 標示估算邊界:無歸因的「quota reset」會被
            // 誤認成別家 provider(使用者實測:Codex/估算事件被讀成 Claude);估算絕不裝官方。
            let reason: String
            let short: String
            if let pid = pet.celebrationProviderId, let win = pet.celebrationWindow {
                let code = shortProviderCode(pid)
                let winFull = win == "5h" ? "5-hour" : win
                let winShort = win == "weekly" ? "wk" : win
                if pet.celebrationEstimated == true {
                    reason = "\(code) \(winFull) block likely reset (estimated) — celebrating."
                    short = "\(code) \(winShort) ~reset"
                } else {
                    reason = "\(code) \(winFull) window just reset — celebrating."
                    short = "\(code) \(winShort) reset!"
                }
            } else {
                reason = "A quota just reset — celebrating."
                short = "quota reset!"
            }
            // 估算邊界的慶祝前綴也不得讀起來像官方事實(summary 會進匯出報告)。
            let prefix = pet.celebrationEstimated == true ? "Quota likely reset (est)! " : "Quota reset! "
            return Result(mood: .celebration, animationSpeed: 1.6, summary: prefix + summary,
                          reason: reason, shortReason: short)
        }
        if anyExhausted {
            // 取「最嚴重窗百分比最高」的耗盡 provider(平手以 providerId 穩定排序);原因帶窗+值+provenance,
            // 避免把 estimated budget(如 Claude 到 99.5%)呈現成官方事實(cross-model SEV1)。
            let ranked = limits.filter { $0.warning == .exhausted }.sorted {
                let a = worstWindow($0)?.pct ?? 0   // 原始 Double 排名
                let b = worstWindow($1)?.pct ?? 0
                return a != b ? a > b : $0.providerId < $1.providerId
            }
            let reason: String
            let short: String
            if let top = ranked.first, let ww = worstWindow(top) {
                let more = ranked.count > 1 ? " (+\(ranked.count - 1) more)" : ""
                let code = shortProviderCode(top.providerId)
                let pct = Int(ww.pct.rounded())
                reason = "\(code) \(ww.window) is \(provenance(ww.conf)) at \(pct)% (limit reached)\(more)."
                short = bubbleQuota(code, ww.window, pct, ww.conf, suffix: " hit\(ranked.count > 1 ? " +\(ranked.count - 1)" : "")")
            } else {
                reason = "A provider hit its usage limit."
                short = "limit hit"
            }
            return Result(mood: .exhausted, animationSpeed: 0.4, summary: summary, reason: reason, shortReason: short)
        }
        if let worst = worstFive, worst >= warnThreshold {
            let t = trigger { $0.fiveHour }
            let reason = t.map { "\($0.code) 5-hour is \(provenance($0.conf)) at \($0.pct)% (warn at \(warnPct)%)." }
                ?? String(format: "5-hour usage at %d%% (warn at %d%%).", Int(worst.rounded()), warnPct)
            let short = t.map { bubbleQuota($0.code, "5-hour", $0.pct, $0.conf) } ?? "5h over warn"
            return Result(mood: .warning, animationSpeed: max(speed, 1.5), summary: summary, reason: reason, shortReason: short)
        }
        if let weekly = worstWeekly, weekly >= warnThreshold {
            let t = trigger { $0.weekly }
            let reason = t.map { "\($0.code) weekly is \(provenance($0.conf)) at \($0.pct)% (warn at \(warnPct)%)." }
                ?? String(format: "Weekly usage at %d%% (warn at %d%%).", Int(weekly.rounded()), warnPct)
            let short = t.map { bubbleQuota($0.code, "weekly", $0.pct, $0.conf) } ?? "wk over warn"
            return Result(mood: .tired, animationSpeed: 0.7, summary: summary, reason: reason, shortReason: short)
        }
        if noProviders || allNoData {
            return Result(mood: .confused, animationSpeed: 0.8, summary: "No usage data yet. " + summary,
                          reason: noProviders ? "No providers detected yet." : "No usage data found yet.",
                          shortReason: noProviders ? "no providers" : "no data yet")
        }
        if anyError {
            return Result(mood: .confused, animationSpeed: 0.8, summary: "Couldn't read a provider log. " + summary,
                          reason: "A provider log couldn't be read.", shortReason: "log unreadable")
        }
        if anyStale {
            return Result(mood: .confused, animationSpeed: 0.8, summary: "Data looks stale. " + summary,
                          reason: "Provider data looks stale (logs may be behind).", shortReason: "data stale")
        }
        let idleMinutes = lastEventAt.map { now.timeIntervalSince($0) / 60 } ?? .infinity
        if idleMinutes > 45 {
            // lastEventAt 可能為 nil(idleMinutes = .infinity)—— 不硬套數字。
            let reason = lastEventAt != nil
                ? "Idle \(Int(idleMinutes)) min — no recent activity."
                : "No recent activity."
            let short = lastEventAt != nil ? "idle \(Int(idleMinutes))m" : "no activity"
            return Result(mood: .sleeping, animationSpeed: 0.3, summary: summary, reason: reason, shortReason: short)
        }
        if pet.hunger < 30 {
            // pet.hunger 是「飽足度」meter(feed 增、衰減減;<30 = 餓)。
            return Result(mood: .hungry, animationSpeed: 1.1, summary: "Hungry! " + summary,
                          reason: "Fullness \(Int(pet.hunger))% — time to feed.", shortReason: "feed me")
        }
        if let until = pet.happyUntil, until > now {
            return Result(mood: .happy, animationSpeed: 1.2, summary: summary,
                          reason: "Recently fed.", shortReason: "just fed")
        }
        if idleMinutes <= 10 {
            // 泡泡不外露「<10m」門檻(讀起來像挑剔「才做不到 10 分」);focused 本質是二元的
            // 「最近有活動」→ 顯示存在而非時長。完整 prose(Dashboard)保留 recency 敘述。
            // 兩模型一致:不用 activeMinutesToday(今日累計 ≠ focused 的最近性,且套 "for N" 會謊稱連續)。
            return Result(mood: .focused, animationSpeed: speed, summary: summary,
                          reason: "Active in the last 10 minutes.", shortReason: "active now")
        }
        return Result(mood: .idle, animationSpeed: min(speed, 1.2), summary: summary,
                      reason: "Calm — nothing needs attention.", shortReason: "all calm")
    }

    /// mood → 疊加在寵物本體旁的小徽章。
    public static func badge(for mood: PetMood) -> String? {
        switch mood {
        case .idle: return nil
        case .focused: return "⌨️"
        case .hungry: return "🍽️"
        case .eating: return nil // 顯示食物本身
        case .happy: return "❤️"
        case .tired: return "😪"
        case .warning: return "⚠️"
        case .exhausted: return "🪫"
        case .sleeping: return "💤"
        case .celebration: return "🎉"
        case .confused: return "❓"
        }
    }
}
