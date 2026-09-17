import Foundation

// MARK: - Provider-reported limits(usage ≠ limits split,M1)
//
// 「Provider-reported limits」與「Local observed usage」是兩個獨立資料域:前者只來自 provider 自己回報的
// 官方讀值(Claude statusline / Codex rollout `rate_limits`),後者來自本機 log。這裡定義 provider-reported
// 這一側的四態欄位、推導規則(單一 precedence contract)、GUI / CLI 共用的封閉文案投影,以及掛在
// `DashboardState.reportedLimits` 上的載體。設計契約:docs/USAGE_LIMITS_SPLIT.internal.md §2。
//
// 不變量(normative):
// - 只有 `.provided` 帶百分比;任何合成 / 估算值(post-reset 0%、budget 估算)永不進 provider-reported %。
// - `.notProvidedBySource` 的唯一來源是 adapter 的 capability 宣告;reading 缺欄位 / hook 缺 / source 不健康
//   永遠是 `.temporarilyUnavailable`。
// - 投影本身不讀 `Date()`:所有相對時間文字由呼叫端注入的 `now` 決定(同一次 dashboard / CLI snapshot 共用)。

/// provider-reported limit 的窗口種類(與 `ProviderLimitState.fiveHour / weekly` 對應)。
public enum LimitWindowKind: Hashable, Sendable {
    case fiveHour
    case weekly
}

/// adapter 對「本 provider 是否有官方 limit 來源」的靜態宣告(adapter 契約的一部分,不是執行期推論)。
/// `.provides(windows:)` 的集合不得為空 —— 「提供但零窗」與 `.notProvided` 不是同一件事的兩種拼法。
public enum ReportedLimitCapability: Equatable, Sendable {
    case provides(windows: Set<LimitWindowKind>)
    case notProvided
}

/// 引擎仲裁後、逐窗口的官方 reading 狀態(`LimitEngine.limitState` 蓋章,與最終回傳哪個 presentation 分支無關):
/// persisted && useOfficial → `.usable`;persisted && !useOfficial → `.expiredUnusable`;!persisted → `.absent`。
/// reading-backed provider(codex)沒有 useOfficial 概念:slot 在 → `.usable`(即使已過期、合成 0%),slot 空 → `.absent`。
public enum OfficialWindowStatus: String, Codable, Sendable {
    case usable
    case expiredUnusable
    case absent
}

/// `.temporarilyUnavailable` 的原因(封閉集合;順序 = precedence 4 → 7)。
public enum ReportedLimitUnavailableReason: String, Codable, Sendable {
    case hookNotInstalled
    case sourceUnhealthy
    case awaitingFreshReading
    case noReadingYet
}

/// provider-reported limit 的四態。`derive` 是唯一的建構路徑(GUI / CLI 不得自行判斷)。
public enum ReportedLimitField: Equatable, Sendable {
    case provided(percent: Double, resetsAt: Date?, confidence: Confidence, corrected: Bool)
    case notProvidedBySource
    case temporarilyUnavailable(ReportedLimitUnavailableReason)
    case unknownCapability

    /// 單一 precedence contract(first match;§2.2 表)。只讀 `window` 的 usedPercent / resetAt / confidence / corrected。
    ///
    /// 1. capability nil → `.unknownCapability`
    /// 2. `.notProvided` ∨ kind ∉ windows → `.notProvidedBySource`
    /// 3. official == .usable ∧ confidence ∈ {.high, .stale} ∧ usedPercent != nil → `.provided`
    /// 4. statuslinePresent == false → `.hookNotInstalled`
    /// 5. sourceHealth != nil ∧ != .ok → `.sourceUnhealthy`
    /// 6. official == .expiredUnusable ∨ (official == .usable ∧ confidence == .estimated) → `.awaitingFreshReading`
    /// 7. otherwise → `.noReadingYet`
    public static func derive(capability: ReportedLimitCapability?, kind: LimitWindowKind, window: LimitWindowState,
                              official: OfficialWindowStatus, statuslinePresent: Bool?,
                              sourceHealth: SourceHealth?) -> ReportedLimitField {
        guard let capability else { return .unknownCapability }                                        // 1
        switch capability {
        case .notProvided:
            return .notProvidedBySource                                                                // 2
        case .provides(let windows):
            if !windows.contains(kind) { return .notProvidedBySource }                                 // 2
        }
        if official == .usable, window.confidence == .high || window.confidence == .stale,
           let percent = window.usedPercent {
            return .provided(percent: percent, resetsAt: window.resetAt,
                             confidence: window.confidence, corrected: window.corrected)                // 3
        }
        if statuslinePresent == false { return .temporarilyUnavailable(.hookNotInstalled) }            // 4
        if let health = sourceHealth, health != .ok { return .temporarilyUnavailable(.sourceUnhealthy) } // 5
        if official == .expiredUnusable || (official == .usable && window.confidence == .estimated) {
            return .temporarilyUnavailable(.awaitingFreshReading)                                      // 6
        }
        return .temporarilyUnavailable(.noReadingYet)                                                  // 7
    }

    /// provided 列的附帶提示(鏡射規則 4 < 5 的順序);非 provided 列不渲染 cue。
    public static func cue(statuslinePresent: Bool?, sourceHealth: SourceHealth?) -> ReportedLimitCue {
        if statuslinePresent == false { return .hookNotDetected }
        if let health = sourceHealth, health != .ok { return .sourceUnhealthy }
        return .none
    }
}

/// provided 列的附帶提示(值仍可信,但來源有狀況)。
public enum ReportedLimitCue: Equatable, Sendable {
    case none
    case hookNotDetected
    case sourceUnhealthy
}

/// 每個 provider 一筆,與 `DashboardState.limitStates` 平行(同 providerId 鍵)。
public struct ProviderReportedLimits: Equatable, Sendable, Identifiable {
    public let providerId: String
    public let fiveHour: ReportedLimitField
    public let weekly: ReportedLimitField
    public let cue: ReportedLimitCue
    /// claude-code:任一 statusline 落地檔是否存在;其他 provider nil。
    public let statuslinePresent: Bool?
    /// estimate 列(既有 Claude budget 估算)對該窗是否啟動(D16):claude-code ∧ official ∈ {expiredUnusable, absent}。
    public let fiveHourEstimateActive: Bool
    public let weeklyEstimateActive: Bool

    public var id: String { providerId }

    public init(providerId: String, fiveHour: ReportedLimitField, weekly: ReportedLimitField, cue: ReportedLimitCue,
                statuslinePresent: Bool?, fiveHourEstimateActive: Bool, weeklyEstimateActive: Bool) {
        self.providerId = providerId
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.cue = cue
        self.statuslinePresent = statuslinePresent
        self.fiveHourEstimateActive = fiveHourEstimateActive
        self.weeklyEstimateActive = weeklyEstimateActive
    }

    /// 由引擎輸出 + adapter capability + presence / F17 健康度推導(coordinator 的唯一組裝路徑)。
    public init(capability: ReportedLimitCapability?, limit: ProviderLimitState,
                statuslinePresent: Bool?, sourceHealth: SourceHealth?) {
        self.init(
            providerId: limit.providerId,
            fiveHour: ReportedLimitField.derive(capability: capability, kind: .fiveHour, window: limit.fiveHour,
                                                official: limit.fiveHourOfficial, statuslinePresent: statuslinePresent,
                                                sourceHealth: sourceHealth),
            weekly: ReportedLimitField.derive(capability: capability, kind: .weekly, window: limit.weekly,
                                              official: limit.weeklyOfficial, statuslinePresent: statuslinePresent,
                                              sourceHealth: sourceHealth),
            cue: ReportedLimitField.cue(statuslinePresent: statuslinePresent, sourceHealth: sourceHealth),
            statuslinePresent: statuslinePresent,
            fiveHourEstimateActive: Self.estimateActive(providerId: limit.providerId, official: limit.fiveHourOfficial),
            weeklyEstimateActive: Self.estimateActive(providerId: limit.providerId, official: limit.weeklyOfficial))
    }

    /// estimate 列啟動條件(D16,normative):永不以 `confidence == .estimated` 判斷(合成 0% 也帶 `.estimated`)。
    public static func estimateActive(providerId: String, official: OfficialWindowStatus) -> Bool {
        providerId == "claude-code" && (official == .expiredUnusable || official == .absent)
    }
}

/// provider-reported 欄位的封閉文案表(GUI / CLI 共用;純函數)。
public enum ReportedLimitText {
    public typealias Rendered = (main: String, secondary: String, gaugePercent: Double?)

    /// `now` 由呼叫端注入(同一次 snapshot 共用);本函數不讀系統時鐘。
    public static func render(field: ReportedLimitField, cue: ReportedLimitCue, now: Date) -> Rendered {
        switch field {
        case .provided(let percent, let resetsAt, let confidence, _):
            var fragments: [String] = []
            if let resetsAt {
                fragments.append("resets in " + ResetLabel.countdown(to: resetsAt, now: now))
            }
            if confidence == .stale { fragments.append("reading is stale") }
            switch cue {
            case .none: break
            case .hookNotDetected: fragments.append("hook not detected")
            case .sourceUnhealthy: fragments.append("source unhealthy")
            }
            return (String(format: "%.1f%%", percent), fragments.joined(separator: " · "), percent)
        case .notProvidedBySource:
            return ("Not provided by this source", "", nil)
        case .temporarilyUnavailable(let reason):
            let secondary: String
            switch reason {
            case .hookNotInstalled: secondary = "Statusline hook not installed"
            case .sourceUnhealthy: secondary = "Source unhealthy — see Settings → Data Health"
            case .awaitingFreshReading: secondary = "Awaiting fresh provider reading"
            case .noReadingYet: secondary = "No reading yet"
            }
            return ("Temporarily unavailable", secondary, nil)
        case .unknownCapability:
            return ("—", "", nil)
        }
    }

    /// 單行形式(Today 卡 `5h: …` 行):主文,次行非空時接 ` · 次行`。
    public static func inline(field: ReportedLimitField, cue: ReportedLimitCue, now: Date) -> String {
        let text = render(field: field, cue: cue, now: now)
        return text.secondary.isEmpty ? text.main : text.main + " · " + text.secondary
    }

    /// 區塊標題(封閉表;Claude 的 account-level 措辭是 owner-locked)。
    public static func header(providerId: String) -> String {
        switch providerId {
        case "claude-code": return "Provider-reported limits · Account-level · Reported by Claude Code"
        case "codex": return "Provider-reported limits · Reported by Codex"
        case "grok-code": return "Provider-reported limits · Grok source"
        case "opencode": return "Provider-reported limits · Reported by OpenCode"
        default: return "Provider-reported limits"
        }
    }

    /// CLI `reported limits:` 行的來源欄(`account-level` 只出現在 claude-code 行)。
    public static func cliSourceLabel(providerId: String) -> String {
        switch providerId {
        case "claude-code": return "account-level · Claude Code"
        case "codex": return "Codex"
        case "grok-code": return "Grok source"
        case "opencode": return "OpenCode"
        default: return providerId
        }
    }
}

/// estimate 列(既有 Claude budget 估算)的封閉文案表;只在 `ProviderReportedLimits.*EstimateActive` 為 true 的窗呼叫。
public enum EstimateRowText {
    public typealias Rendered = (main: String, secondary: String)

    /// first match:idle → `idle` / `no active 5h window`;有 % → `NN.N%` / `<used>/<budget> tokens` + period;
    /// 有 tokens 無 budget → `<tokens> tokens` / `no budget set` + period;有 tokens 有 budget(無 %)→ `<tokens> tokens` / period;
    /// 其他 → `no local Claude usage found`。period:5h 有 resetAt → `resets in …`;weekly → `rolling 7-day`。
    public static func render(window: LimitWindowState, kind: LimitWindowKind, now: Date) -> Rendered {
        if window.idle { return ("idle", "no active 5h window") }
        let period: String?
        switch kind {
        case .fiveHour: period = window.resetAt.map { "resets in " + ResetLabel.countdown(to: $0, now: now) }
        case .weekly: period = "rolling 7-day"
        }
        var fragments: [String] = []
        let main: String
        if let percent = window.usedPercent {
            main = String(format: "%.1f%%", percent)
            if let used = window.usedTokens, let budget = window.budgetTokens {
                fragments.append("\(ReportGenerator.fmtTokens(used))/\(ReportGenerator.fmtTokens(budget)) tokens")
            }
        } else if let used = window.usedTokens {
            main = "\(ReportGenerator.fmtTokens(used)) tokens"
            if window.budgetTokens == nil { fragments.append("no budget set") }
        } else {
            return ("no local Claude usage found", "")
        }
        if let period { fragments.append(period) }
        return (main, fragments.joined(separator: " · "))
    }

    /// Today 卡第 7 行(恆渲染):claude 至少一窗 active → `Estimated from local logs (your budget) · 5h: … · weekly: …`
    /// (inactive 的窗顯 `—`);claude 兩窗皆 inactive → `Estimated from local logs (your budget) · —`;非 claude → `—`。
    public static func todayLine(reported: ProviderReportedLimits, limit: ProviderLimitState, now: Date) -> String {
        guard reported.providerId == "claude-code" else { return "—" }
        let prefix = "Estimated from local logs (your budget)"
        guard reported.fiveHourEstimateActive || reported.weeklyEstimateActive else { return prefix + " · —" }
        func column(_ label: String, active: Bool, window: LimitWindowState, kind: LimitWindowKind) -> String {
            guard active else { return label + ": —" }
            let text = render(window: window, kind: kind, now: now)
            return label + ": " + (text.secondary.isEmpty ? text.main : text.main + " · " + text.secondary)
        }
        return prefix + " · "
            + column("5h", active: reported.fiveHourEstimateActive, window: limit.fiveHour, kind: .fiveHour)
            + " · "
            + column("weekly", active: reported.weeklyEstimateActive, window: limit.weekly, kind: .weekly)
    }
}

/// Limits 頁 estimate bar 的 view-model(v0.8 A2b:GUI view `EstimateBar` 的**唯一**文字來源;
/// text 全數 delegate 給 `EstimateRowText.render`、gauge = estimate-domain `window.usedPercent`)。
/// 這層薄封裝讓「Limits estimate bar 只吃 EstimateRowText vocabulary」成為 headless 可測事實
///(view 是啞渲染;若此處改成自呼 countdown / 自拼字串,vocabulary / injected-now 測試即 RED)。
public enum EstimateBarText {
    public typealias Rendered = (main: String, secondary: String, gaugePercent: Double?)
    public static func render(window: LimitWindowState, kind: LimitWindowKind, now: Date) -> Rendered {
        let text = EstimateRowText.render(window: window, kind: kind, now: now)   // 唯一 vocabulary source
        return (text.main, text.secondary, window.usedPercent)
    }
}

/// `Set estimated budget…` 按鈕的顯示條件(D13:affordance 是 estimate 域控制,不由四態驅動)。
public enum BudgetAffordance {
    /// Today 卡按鈕(snapshot 驅動;判斷式與 M1 之前 `AgentCard` 內的字面完全相同)。
    public static func todayButtonVisible(snapshot: UsageSnapshot, limit: ProviderLimitState?) -> Bool {
        snapshot.sessionUsagePercent == nil && snapshot.providerId == "claude-code"
            && limit?.fiveHour.idle != true && limit?.fiveHour.budgetTokens == nil
    }

    /// Limits 頁 estimate bar 的 affordance(v0.8 A2b:抽自 v0.7 前 `LimitBar` 的逐窗判斷式,
    /// 規則一字不改 —— `usedPercent == nil ∧ !idle ∧ budgetTokens == nil ∧ showBudgetAffordance`;
    /// 逐 bar 各自評估,含 weekly。與 Today 按鈕的 snapshot-based predicate 刻意不同,R-A4)。
    public static func limitsEstimateBarShowsBudgetButton(window: LimitWindowState, showBudgetAffordance: Bool) -> Bool {
        window.usedPercent == nil && !window.idle && window.budgetTokens == nil && showBudgetAffordance
    }
}
