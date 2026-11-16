import Foundation

/// 「as of …」年齡標籤:provider 回報值(Claude statusline 週窗 / model-scoped)超過門檻仍保留數值,
/// 但必須標出讀數年齡 —— desktop(Code tab)session 不呼叫 statusline hook,讀數可能停更數小時。
public enum StatuslineAge {
    /// 30 分鐘:hook 在 terminal session 活躍時每次刷新都寫檔,半小時沒更新已足以代表「不是即時值」,
    /// 又不會在正常的短暫閒置中頻繁閃現標籤。
    public static let labelThreshold: TimeInterval = 30 * 60

    /// 年齡 ≤ 門檻、無觀測時間 → nil;否則 "as of 45m ago" / "as of 10h ago" / "as of 2d ago"。
    public static func asOfLabel(observedAt: Date?, now: Date) -> String? {
        guard let observedAt else { return nil }
        let age = now.timeIntervalSince(observedAt)
        guard age > labelThreshold else { return nil }
        if age < 3600 { return "as of \(Int(age / 60))m ago" }
        if age < 86400 { return "as of \(Int(age / 3600))h ago" }
        return "as of \(Int(age / 86400))d ago"
    }

    /// 只對 Claude 帳戶列與 model-scoped 列的週窗標示(其他 provider 有各自的陳舊度呈現)。
    public static func weeklyAsOfLabel(for state: ProviderLimitState, now: Date) -> String? {
        guard ClaudeScopedDisplay.isClaudeChromeId(state.providerId), state.weekly.usedPercent != nil else { return nil }
        return asOfLabel(observedAt: state.weekly.observedAt, now: now)
    }
}

/// Splits Claude Code account limits vs model-scoped weekly buckets (e.g. Fable) for chrome surfaces.
public enum ClaudeScopedDisplay {
    public static let fableId = "claude-code-fable"

    public static let scopedChromeOrder = [fableId]

    public static func chromeId(forDisplayName name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("fable") { return fableId }
        let slug = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        guard !slug.isEmpty else { return nil }
        return "claude-code-scoped-\(slug)"
    }

    public static func displayName(forChromeId id: String) -> String? {
        switch id {
        case fableId: return "Claude Code · Fable"
        default:
            if id.hasPrefix("claude-code-scoped-") {
                let slug = String(id.dropFirst("claude-code-scoped-".count))
                return "Claude Code · \(slug)"
            }
            return nil
        }
    }

    public static func meterLabel(forChromeId id: String) -> String? {
        switch id {
        case fableId: return "Fable"
        default:
            if id.hasPrefix("claude-code-scoped-") {
                return String(id.dropFirst("claude-code-scoped-".count))
            }
            return nil
        }
    }

    public static func sortKey(forChromeId id: String) -> String? {
        switch id {
        case "claude-code": return "claude code · 1 account"
        case fableId: return "claude code · 2 fable"
        default:
            if id.hasPrefix("claude-code-scoped-") {
                return "claude code · 9 \(id.dropFirst("claude-code-scoped-".count))"
            }
            return nil
        }
    }

    public static func isScopedChromeId(_ providerId: String) -> Bool {
        providerId == fableId || providerId.hasPrefix("claude-code-scoped-")
    }

    public static func isClaudeChromeId(_ providerId: String) -> Bool {
        providerId == "claude-code" || isScopedChromeId(providerId)
    }

    /// After the account row, append one limit row per model-scoped weekly window from statusline.
    public static func expandLimitStates(_ states: [ProviderLimitState]) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        for st in states {
            if isScopedChromeId(st.providerId) { continue }
            out.append(st)
            guard st.providerId == "claude-code", let scoped = st.modelScopedWeekly, !scoped.isEmpty else { continue }
            for row in scoped {
                guard let pid = chromeId(forDisplayName: row.displayName) else { continue }
                out.append(syntheticLimitState(row: row, providerId: pid, base: st))
            }
        }
        return out
    }

    private static func syntheticLimitState(row: ModelScopedLimitWindow,
                                            providerId: String,
                                            base: ProviderLimitState) -> ProviderLimitState {
        let weekly = LimitWindowState(
            usedPercent: row.usedPercent,
            resetAt: row.resetsAt,
            windowMinutes: 10_080,
            confidence: .high,
            idle: false,
            observedAt: row.observedAt)
        let five = LimitWindowState(windowMinutes: 300, confidence: .high, idle: true)
        return ProviderLimitState(
            providerId: providerId,
            fiveHour: five,
            weekly: weekly,
            burnRateTokensPerHour: 0,
            lastEventAt: base.lastEventAt,
            lastReadingAt: row.observedAt,
            warning: .ok,
            planType: base.planType,
            lastSourceDescription: "Claude Code statusline · \(row.displayName)",
            fiveHourOfficial: .absent,
            weeklyOfficial: .usable,
            todayActivityPercent: nil,
            modelScopedWeekly: nil)
    }
}