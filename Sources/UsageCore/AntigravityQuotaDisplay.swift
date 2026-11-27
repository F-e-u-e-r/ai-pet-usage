import Foundation

/// Splits official `agy /usage` into chrome surfaces (menu badges, pet rings, menu panel).
/// Current agy exposes **Gemini Models** and **Claude and GPT models** (Argon models share the Gemini buckets).
public enum AntigravityQuotaDisplay {
    public static let geminiId = "antigravity-gemini"
    public static let claudeGptId = "antigravity-claude-gpt"
    /// Legacy id when an old `antigravity-quota.json` still has a separate **Gemini 4 Argon** group.
    public static let argonId = "antigravity-argon"

    public static let categoryName = "Antigravity"

    public static let quotaChromeOrder = [geminiId, claudeGptId]

    public static func groupId(forGroupName name: String) -> String? {
        switch name {
        case "Gemini Models": return geminiId
        case "Claude and GPT models": return claudeGptId
        case "Gemini 4 Argon": return argonId
        default: return nil
        }
    }

    /// Full name (menu-bar badges, sorting, a11y).
    public static func displayName(forGroupId id: String) -> String? {
        switch id {
        case geminiId: return "\(categoryName) · Gemini models"
        case claudeGptId: return "\(categoryName) · Claude & GPT"
        case argonId: return "\(categoryName) · Argon"
        default: return nil
        }
    }

    /// Short sub-meter label under the Antigravity category (settings, menu dropdown).
    public static func meterLabel(forGroupId id: String) -> String? {
        switch id {
        case geminiId: return "Gemini models"
        case claudeGptId: return "Claude & GPT"
        case argonId: return "Gemini 4 Argon"
        default: return nil
        }
    }

    public static func sortKey(forGroupId id: String) -> String? {
        switch id {
        case geminiId: return "\(categoryName.lowercased()) · 1 gemini models"
        case claudeGptId: return "\(categoryName.lowercased()) · 2 claude & gpt"
        case argonId: return "\(categoryName.lowercased()) · 3 argon"
        default: return nil
        }
    }

    /// Dashboard / expand order (matches Antigravity Usage UI; appends legacy groups from old snapshots).
    public static func orderedGroups(_ groups: [AntigravityQuotaGroup]) -> [AntigravityQuotaGroup] {
        var seen = Set<String>()
        var out: [AntigravityQuotaGroup] = []
        for pid in quotaChromeOrder {
            if let g = groups.first(where: { groupId(forGroupName: $0.name) == pid }) {
                out.append(g)
                seen.insert(g.name)
            }
        }
        for g in groups where !seen.contains(g.name) {
            guard groupId(forGroupName: g.name) != nil else { continue }
            out.append(g)
        }
        return out
    }

    public static func shortCode(forGroupId id: String) -> String? {
        switch id {
        case geminiId: return "Gm"
        case claudeGptId: return "3P"
        case argonId: return "Ar"
        default: return nil
        }
    }

    public static func isQuotaChromeId(_ providerId: String) -> Bool {
        providerId == geminiId || providerId == claudeGptId || providerId == argonId
    }

  /// One `ProviderLimitState` per Antigravity quota group (official used % + reset).
    public static func syntheticLimitStates(from quota: AntigravityQuotaSnapshot,
                                            base: ProviderLimitState?,
                                            now: Date = Date()) -> [ProviderLimitState] {
        orderedGroups(quota.groups).compactMap { group in
            guard let pid = groupId(forGroupName: group.name) else { return nil }
            let five = group.buckets.first { $0.windowMinutes == 300 }
            let week = group.buckets.first { $0.windowMinutes == 10_080 }
            // The snapshot only refreshes while `agy /usage` succeeds; a failing fetch leaves it on disk.
            // Windows that reset since then lose their value, and an old snapshot is flagged stale.
            let stale = now.timeIntervalSince(quota.fetchedAt) > StatuslineAge.labelThreshold
            let fiveExpired = five.map { isExpired($0, fetchedAt: quota.fetchedAt, now: now) } ?? false
            let weekExpired = week.map { isExpired($0, fetchedAt: quota.fetchedAt, now: now) } ?? false
            return ProviderLimitState(
                providerId: pid,
                fiveHour: windowState(from: fiveExpired ? nil : five, defaultMinutes: 300,
                                      observedAt: quota.fetchedAt),
                weekly: windowState(from: weekExpired ? nil : week, defaultMinutes: 10_080,
                                    observedAt: quota.fetchedAt),
                burnRateTokensPerHour: base?.burnRateTokensPerHour ?? 0,
                lastEventAt: base?.lastEventAt,
                lastReadingAt: quota.fetchedAt,
                warning: stale ? .stale : .ok,
                planType: base?.planType,
                lastSourceDescription: "agy:/usage · \(group.name)",
                fiveHourOfficial: five == nil ? .absent : (fiveExpired ? .expiredUnusable : .usable),
                weeklyOfficial: week == nil ? .absent : (weekExpired ? .expiredUnusable : .usable),
                todayActivityPercent: nil)
        }
    }

    /// Pet rings: at most one Antigravity arc (Gemini 5h primary) so Grok/Cursor token rings are not crowded out.
    public static func collapseForPetRings(_ states: [ProviderLimitState]) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        var insertedAntigravity = false
        for st in states {
            if isQuotaChromeId(st.providerId) {
                guard !insertedAntigravity else { continue }
                if let gemini = states.first(where: { $0.providerId == geminiId }) {
                    out.append(gemini)
                } else if let any = states.first(where: { isQuotaChromeId($0.providerId) }) {
                    out.append(any)
                }
                insertedAntigravity = true
            } else {
                out.append(st)
            }
        }
        return out
    }

    /// Replace the single `antigravity` row with three quota rows when snapshot is present.
    public static func expandLimitStates(_ states: [ProviderLimitState],
                                         quota: AntigravityQuotaSnapshot?,
                                         now: Date = Date()) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        for st in states {
            if st.providerId == "antigravity", let quota, !quota.groups.isEmpty {
                let synth = syntheticLimitStates(from: quota, base: st, now: now)
                if !synth.isEmpty {
                    out.append(contentsOf: synth)
                    continue
                }
            }
            out.append(st)
        }
        return out
    }

    /// Past its reset, or (no reset time) older than its own window.
    public static func isExpired(_ bucket: AntigravityQuotaBucket, fetchedAt: Date, now: Date) -> Bool {
        if let resetsAt = AntigravityQuotaFetcher.normalizedResetTime(bucket.resetsAt) { return resetsAt <= now }
        return now.timeIntervalSince(fetchedAt) > Double(bucket.windowMinutes) * 60
    }

    /// Dashboard line for one bucket: an expired window shows no value (same rule as the menu rows).
    public static func bucketSummary(_ bucket: AntigravityQuotaBucket, fetchedAt: Date, now: Date) -> String {
        if isExpired(bucket, fetchedAt: fetchedAt, now: now) { return "— · awaiting agy /usage refresh" }
        return "\(Int(bucket.remainingPercent.rounded()))% left · \(ResetLabel.countdown(to: bucket.resetsAt, now: now))"
    }

    private static func windowState(from bucket: AntigravityQuotaBucket?,
                                    defaultMinutes: Int, observedAt: Date) -> LimitWindowState {
        guard let bucket else {
            return LimitWindowState(windowMinutes: defaultMinutes, confidence: .high, idle: false)
        }
        return LimitWindowState(usedPercent: bucket.usedPercent,
                                resetAt: AntigravityQuotaFetcher.normalizedResetTime(bucket.resetsAt),
                                windowMinutes: bucket.windowMinutes,
                                confidence: .high,
                                idle: false,
                                observedAt: observedAt)
    }
}