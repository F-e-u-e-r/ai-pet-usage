import Foundation

// Provider 識別徽章系統(UIUX spec):
//   dot 顏色 = provider 身分,恆定不變,絕不隨用量改色;
//   百分比文字顏色 = severity(normal / warn 橘 / danger 紅)。
// 兩者職責分離——dot 不是警示燈。短代號用於選單列/量表等窄空間,
// 全名用於 dropdown、hover、輔助功能與報告。

public struct ProviderBrand: Sendable, Equatable {
    public let id: String
    /// 選單列/迷你量表用「極短代號」(CC/CX/AG/GK)— 寬度最吝嗇的場合。
    public let code: String
    /// 面板列/表格欄用「中等短名」(Claude/Codex/Grok)— 一眼可讀但不佔滿列寬;
    /// reset 倒數等右側資訊因此不再被截斷。
    public let shortName: String
    /// dropdown hover、輔助功能、報告用全名(Claude Code/Grok Code)。
    public let displayName: String
    /// 身分 dot 顏色(0xRRGGBB)。
    public let dotColor: UInt32
    /// 深色 dot(GK 碳黑)需要淺色描邊,否則融入深色選單列/儀表板。
    public let needsOutline: Bool

    public init(id: String, code: String, shortName: String, displayName: String,
                dotColor: UInt32, needsOutline: Bool) {
        self.id = id
        self.code = code
        self.shortName = shortName
        self.displayName = displayName
        self.dotColor = dotColor
        self.needsOutline = needsOutline
    }
}

public enum ProviderBrands {
    /// 已知 provider 的固定識別色。AG 規格建議 rainbow,選單列尺寸下改用紫色替代
    /// (spec 自己註明 rainbow 太吵時 fallback 紫色)。
    public static let known: [ProviderBrand] = [
        ProviderBrand(id: "antigravity", code: "AG", shortName: "Antigravity", displayName: "Antigravity",
                      dotColor: 0x8B5CF6, needsOutline: false),
        ProviderBrand(id: "claude-code", code: "CC", shortName: "Claude", displayName: "Claude Code",
                      dotColor: 0xE8823A, needsOutline: false),
        ProviderBrand(id: "codex", code: "CX", shortName: "Codex", displayName: "Codex",
                      dotColor: 0x3B82F6, needsOutline: false),
        ProviderBrand(id: "grok-code", code: "GK", shortName: "Grok", displayName: "Grok Code",
                      dotColor: 0x2E3138, needsOutline: true),
    ]

    public static func brand(for providerId: String, displayName: String? = nil) -> ProviderBrand {
        if let hit = known.first(where: { $0.id == providerId }) { return hit }
        return ProviderBrand(id: providerId,
                             code: shortProviderCode(providerId),
                             shortName: displayName ?? providerId,
                             displayName: displayName ?? providerId,
                             dotColor: 0x9AA1AB,
                             needsOutline: false)
    }
}

/// 百分比 severity → 文字顏色(閾值來自使用者設定,預設 warn 80 / danger 95;
/// spec 的固定 90 改綁設定值,避免與可調整的 danger 閾值互相矛盾)。
public enum UsageSeverity: String, Sendable, Equatable {
    case normal, warn, danger

    public static func of(percent: Double?, warn: Double, danger: Double) -> UsageSeverity {
        guard let p = percent else { return .normal }
        if p >= danger { return .danger }
        if p >= warn { return .warn }
        return .normal
    }

    /// 輔助功能朗讀用字("Claude Code 91 percent, warning")。
    public var accessibilityWord: String {
        switch self {
        case .normal: return "normal"
        case .warn: return "warning"
        case .danger: return "critical"
        }
    }
}

/// 選單列徽章:一家 provider 的 dot + 代號 + 兩個時窗(5h / weekly)各自 severity 上色的百分比。
public struct MenuBadge: Sendable, Equatable, Identifiable {
    /// 單一時窗的顯示值(percent 已四捨五入為整數;severity 依該窗自身閾值,獨立上色)。
    public struct Window: Sendable, Equatable {
        public let percent: Int
        public let severity: UsageSeverity
        public init(percent: Int, severity: UsageSeverity) {
            self.percent = percent
            self.severity = severity
        }
    }

    public let providerId: String
    public let code: String
    public let displayName: String
    public let dotColor: UInt32
    public let needsOutline: Bool
    /// 5h 滾動窗;nil = 該窗無資料 / idle(顯示 "-",不併入 no-data)。
    public let fiveHour: Window?
    /// weekly 滾動窗;nil = 該窗無資料(顯示 "-")。
    public let weekly: Window?
    /// true = 該 provider 有近期活動但**兩窗皆無資料** → 顯示中性「idle」而非百分比(不丟徽章)。
    public let idle: Bool

    public var id: String { providerId }

    public init(providerId: String, code: String, displayName: String, dotColor: UInt32,
                needsOutline: Bool, fiveHour: Window?, weekly: Window?, idle: Bool = false) {
        self.providerId = providerId
        self.code = code
        self.displayName = displayName
        self.dotColor = dotColor
        self.needsOutline = needsOutline
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.idle = idle
    }

    /// compact 過濾用的整體 severity:兩窗取較嚴重者(排序仍依 displayName 字母序,與此無關)。
    public var aggregateSeverity: UsageSeverity {
        let severities = [fiveHour?.severity, weekly?.severity].compactMap { $0 }
        if severities.contains(.danger) { return .danger }
        if severities.contains(.warn) { return .warn }
        return .normal
    }
}

public enum MenuBadgeBuilder {
    /// 由 (providerId, displayName, 5h%, weekly%) 建出選單列徽章。規則(spec §2/§5):
    /// 依顯示名稱字母序穩定排序(不得依 severity 重排)、identity 色恆定、
    /// 每窗 severity 只上在該窗自己的百分比文字;compact(onlyWarnings)= **任一窗**達 warn 才顯示
    /// (否則高 weekly 會在 compact 模式消失 —— 正是本功能要防的漏報)。
    /// 兩窗皆無資料:idle → 顯示中性「idle」徽章(compact 省略);非 idle → 略過(未偵測/無資料)。
    public static func badges(
        from states: [(id: String, displayName: String?, fiveHour: Double?, weekly: Double?, idle: Bool)],
        warn: Double, danger: Double,
        onlyWarnings: Bool = false
    ) -> [MenuBadge] {
        func window(_ percent: Double?) -> MenuBadge.Window? {
            percent.map { MenuBadge.Window(percent: Int($0.rounded()),
                                           severity: .of(percent: $0, warn: warn, danger: danger)) }
        }
        return states.compactMap { st -> MenuBadge? in
            let brand = ProviderBrands.brand(for: st.id, displayName: st.displayName)
            let fiveHour = window(st.fiveHour)
            let weekly = window(st.weekly)
            // 兩窗皆無資料:idle 顯示中性徽章(compact 除外);否則整筆略過(無資料)。
            if fiveHour == nil, weekly == nil {
                guard st.idle, !onlyWarnings else { return nil }
                return MenuBadge(providerId: st.id, code: brand.code, displayName: brand.displayName,
                                 dotColor: brand.dotColor, needsOutline: brand.needsOutline,
                                 fiveHour: nil, weekly: nil, idle: true)
            }
            let badge = MenuBadge(providerId: st.id, code: brand.code, displayName: brand.displayName,
                                  dotColor: brand.dotColor, needsOutline: brand.needsOutline,
                                  fiveHour: fiveHour, weekly: weekly, idle: false)
            // compact:任一窗達 warn 才顯示。
            if onlyWarnings, badge.aggregateSeverity == .normal { return nil }
            return badge
        }
        .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// 輔助功能全句(spec §11:不得只朗讀 "CC 91 CX 53";兩窗需明確念「5-hour」「weekly」)。
    /// 例:"Golden Retriever. Claude Code 5-hour 91 percent, warning, weekly 40 percent, normal."
    public static func accessibilitySummary(petName: String?, badges: [MenuBadge]) -> String {
        var parts: [String] = []
        if let petName, !petName.isEmpty { parts.append(petName) }
        if badges.isEmpty {
            parts.append("No usage data")
        } else {
            parts.append(contentsOf: badges.map { badge in
                if badge.idle { return "\(badge.displayName) idle" }
                func say(_ label: String, _ w: MenuBadge.Window?) -> String {
                    w.map { "\(label) \($0.percent) percent, \($0.severity.accessibilityWord)" }
                        ?? "\(label) no data"
                }
                return "\(badge.displayName) \(say("5-hour", badge.fiveHour)), \(say("weekly", badge.weekly))"
            })
        }
        return parts.joined(separator: ". ") + "."
    }
}
