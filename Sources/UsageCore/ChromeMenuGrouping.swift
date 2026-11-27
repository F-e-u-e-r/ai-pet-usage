import Foundation

/// Groups multi-meter provider chrome (Antigravity buckets, Cursor plan usage) for menu, settings, and sort order.
public enum ChromeMenuGrouping {
    public enum Segment: Sendable {
        case provider(ProviderLimitState)
        case antigravityGroup([ProviderLimitState])
        case claudeGroup([ProviderLimitState])
        case cursorGroup([ProviderLimitState])
    }

    public struct Partition: Sendable {
        public var others: [ProviderLimitState]
        public var antigravity: [ProviderLimitState]
        public var claude: [ProviderLimitState]
        public var cursor: [ProviderLimitState]
    }

    public static func isQuotaChromeId(_ id: String) -> Bool {
        AntigravityQuotaDisplay.isQuotaChromeId(id) || CursorQuotaDisplay.isQuotaChromeId(id)
    }

    public static func sortKey(for st: ProviderLimitState) -> String {
        AntigravityQuotaDisplay.sortKey(forGroupId: st.providerId)
            ?? ClaudeScopedDisplay.sortKey(forChromeId: st.providerId)
            ?? CursorQuotaDisplay.sortKey(forChromeId: st.providerId)
            ?? st.providerId
    }

    public static func partition(_ states: [ProviderLimitState]) -> Partition {
        var others: [ProviderLimitState] = []
        var antigravity: [ProviderLimitState] = []
        var claude: [ProviderLimitState] = []
        var cursor: [ProviderLimitState] = []
        for st in states {
            if AntigravityQuotaDisplay.isQuotaChromeId(st.providerId) {
                antigravity.append(st)
            } else if ClaudeScopedDisplay.isClaudeChromeId(st.providerId) {
                claude.append(st)
            } else if CursorQuotaDisplay.isQuotaChromeId(st.providerId) {
                cursor.append(st)
            } else {
                others.append(st)
            }
        }
        antigravity.sort { orderIndex(AntigravityQuotaDisplay.quotaChromeOrder, $0.providerId)
            < orderIndex(AntigravityQuotaDisplay.quotaChromeOrder, $1.providerId) }
        claude.sort {
            let order = (["claude-code"] + ClaudeScopedDisplay.scopedChromeOrder)
            return orderIndex(order, $0.providerId) < orderIndex(order, $1.providerId)
        }
        cursor.sort { orderIndex([CursorQuotaDisplay.autoId, CursorQuotaDisplay.apiId], $0.providerId)
            < orderIndex([CursorQuotaDisplay.autoId, CursorQuotaDisplay.apiId], $1.providerId) }
        others.sort { sortKey(for: $0).lowercased() < sortKey(for: $1).lowercased() }
        return Partition(others: others, antigravity: antigravity, claude: claude, cursor: cursor)
    }

    /// Stable menu / badge order; quota chrome ids sort adjacent under their category prefix.
    public static func orderForMenu(_ states: [ProviderLimitState]) -> [ProviderLimitState] {
        states.sorted { sortKey(for: $0).lowercased() < sortKey(for: $1).lowercased() }
    }

    public static func menuSegments(_ orderedStates: [ProviderLimitState]) -> [Segment] {
        var out: [Segment] = []
        var i = 0
        while i < orderedStates.count {
            let id = orderedStates[i].providerId
            if AntigravityQuotaDisplay.isQuotaChromeId(id) {
                var group: [ProviderLimitState] = []
                while i < orderedStates.count, AntigravityQuotaDisplay.isQuotaChromeId(orderedStates[i].providerId) {
                    group.append(orderedStates[i])
                    i += 1
                }
                out.append(.antigravityGroup(group))
            } else if ClaudeScopedDisplay.isClaudeChromeId(id) {
                var group: [ProviderLimitState] = []
                while i < orderedStates.count, ClaudeScopedDisplay.isClaudeChromeId(orderedStates[i].providerId) {
                    group.append(orderedStates[i])
                    i += 1
                }
                out.append(.claudeGroup(group))
            } else if CursorQuotaDisplay.isQuotaChromeId(id) {
                var group: [ProviderLimitState] = []
                while i < orderedStates.count, CursorQuotaDisplay.isQuotaChromeId(orderedStates[i].providerId) {
                    group.append(orderedStates[i])
                    i += 1
                }
                out.append(.cursorGroup(group))
            } else {
                out.append(.provider(orderedStates[i]))
                i += 1
            }
        }
        return out
    }

    private static func orderIndex(_ order: [String], _ id: String) -> Int {
        order.firstIndex(of: id) ?? order.count
    }
}