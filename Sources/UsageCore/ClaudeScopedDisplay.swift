import Foundation

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
            idle: false)
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