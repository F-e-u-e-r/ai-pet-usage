import Foundation

// Provider 識別徽章系統(UIUX spec):
//   dot 顏色 = provider 身分,恆定不變,絕不隨用量改色;
//   百分比文字顏色 = severity(normal / warn 橘 / danger 紅)。
// 兩者職責分離——dot 不是警示燈。短代號用於選單列/量表等窄空間,
// 全名用於 dropdown、hover、輔助功能與報告。

public struct ProviderBrand: Sendable, Equatable {
    public let id: String
    /// 選單列/迷你量表用短代號(CC/CX/AG/GK)。
    public let code: String
    /// dropdown、hover、輔助功能、報告用全名。
    public let displayName: String
    /// 身分 dot 顏色(0xRRGGBB)。
    public let dotColor: UInt32
    /// 深色 dot(GK 碳黑)需要淺色描邊,否則融入深色選單列/儀表板。
    public let needsOutline: Bool

    public init(id: String, code: String, displayName: String, dotColor: UInt32, needsOutline: Bool) {
        self.id = id
        self.code = code
        self.displayName = displayName
        self.dotColor = dotColor
        self.needsOutline = needsOutline
    }
}

public enum ProviderBrands {
    /// 已知 provider 的固定識別色。AG 規格建議 rainbow,選單列尺寸下改用紫色替代
    /// (spec 自己註明 rainbow 太吵時 fallback 紫色)。
    public static let known: [ProviderBrand] = [
        ProviderBrand(id: "antigravity", code: "AG", displayName: "Antigravity",
                      dotColor: 0x8B5CF6, needsOutline: false),
        ProviderBrand(id: "claude-code", code: "CC", displayName: "Claude Code",
                      dotColor: 0xE8823A, needsOutline: false),
        ProviderBrand(id: "codex", code: "CX", displayName: "Codex",
                      dotColor: 0x3B82F6, needsOutline: false),
        ProviderBrand(id: "grok-code", code: "GK", displayName: "Grok Code",
                      dotColor: 0x2E3138, needsOutline: true),
    ]

    public static func brand(for providerId: String, displayName: String? = nil) -> ProviderBrand {
        if let hit = known.first(where: { $0.id == providerId }) { return hit }
        return ProviderBrand(id: providerId,
                             code: shortProviderCode(providerId),
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

/// 選單列徽章:一家 provider 的 dot + 代號 + severity 上色的百分比。
public struct MenuBadge: Sendable, Equatable, Identifiable {
    public let providerId: String
    public let code: String
    public let displayName: String
    public let dotColor: UInt32
    public let needsOutline: Bool
    public let percent: Int
    public let severity: UsageSeverity

    public var id: String { providerId }

    public init(providerId: String, code: String, displayName: String, dotColor: UInt32,
                needsOutline: Bool, percent: Int, severity: UsageSeverity) {
        self.providerId = providerId
        self.code = code
        self.displayName = displayName
        self.dotColor = dotColor
        self.needsOutline = needsOutline
        self.percent = percent
        self.severity = severity
    }
}

public enum MenuBadgeBuilder {
    /// 由 (providerId, displayName, 5h%) 建出選單列徽章。規則(spec §2/§5):
    /// 依顯示名稱字母序穩定排序(不得依 severity 重排)、未偵測/無資料省略、
    /// identity 色恆定、severity 只上在百分比文字。
    public static func badges(from states: [(id: String, displayName: String?, percent: Double?)],
                              warn: Double, danger: Double,
                              onlyWarnings: Bool = false) -> [MenuBadge] {
        states.compactMap { st -> MenuBadge? in
            guard let p = st.percent else { return nil }
            let brand = ProviderBrands.brand(for: st.id, displayName: st.displayName)
            let severity = UsageSeverity.of(percent: p, warn: warn, danger: danger)
            if onlyWarnings, severity == .normal { return nil }
            return MenuBadge(providerId: st.id, code: brand.code, displayName: brand.displayName,
                             dotColor: brand.dotColor, needsOutline: brand.needsOutline,
                             percent: Int(p.rounded()), severity: severity)
        }
        .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    /// 輔助功能全句(spec §11:不得只朗讀 "CC 91 CX 53")。
    /// 例:"Golden Retriever. Claude Code 91 percent, warning. Codex 53 percent, normal."
    public static func accessibilitySummary(petName: String?, badges: [MenuBadge]) -> String {
        var parts: [String] = []
        if let petName, !petName.isEmpty { parts.append(petName) }
        if badges.isEmpty {
            parts.append("No usage data")
        } else {
            parts.append(contentsOf: badges.map {
                "\($0.displayName) \($0.percent) percent, \($0.severity.accessibilityWord)"
            })
        }
        return parts.joined(separator: ". ") + "."
    }
}
